#!/usr/bin/env bash
# Stubbed test for the ec2 launcher. Usage: test.sh <path-to-ec2-binary>.
# The launcher runs with stub aws, nix, coldsnap, curl and ssh on PATH; each stub
# appends its argv to $STUB_LOG. coldsnap runs only in a case where an image
# rebuild is expected. No network access is made.
set -uo pipefail

EC2=$1
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
STUB_LOG="$work/calls.log"
STUB_FIXTURES="$work/fixtures"
OUT="$work/stdout"
ERR="$work/stderr"
ENV_FILE="$work/aws.env"
TS_ENV_FILE="$work/ts.env"
SECRET="SECRET-STUB-VALUE-7f3a9c"
TS_SECRET="TS-SECRET-STUB-3c8d"
TOKEN="TOKEN-STUB-4b1e"
AUTHKEY="tskey-auth-STUB-AUTHKEY-9e2b"
BODY='{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":["tag:ec2"]}}},"expirySeconds":600}'
export STUB_LOG STUB_FIXTURES
export PATH="$work/bin:$PATH"
export EC2_FLEET_FLAKE=/fixture/flake
export XDG_STATE_HOME="$work/state"
export TMPDIR="$work/tmp"
mkdir -p "$work/bin" "$STUB_FIXTURES" "$TMPDIR"
: >"$STUB_LOG"

failures=0
STATUS=0
expect_rebuild=no

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# write_stub <name> reads the stub body from stdin and prefixes it with a
# line that logs the tool name and argv to $STUB_LOG.
write_stub() {
  local name=$1
  {
    echo '#!/bin/sh'
    echo "printf '%s %s\\n' '$name' \"\$*\" >> \"\$STUB_LOG\""
    cat
  } >"$work/bin/$name"
  chmod +x "$work/bin/$name"
}

write_stub aws <<'AWSSTUB'
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || {
  echo "stub aws: no credentials in environment" >&2
  exit 1
}
[ -e "$STUB_FIXTURES/fail-$1-$2" ] && {
  echo "An error occurred (AccessDenied) when calling $2" >&2
  exit 255
}
if [ "$1" = pricing ]; then
  itype=
  for a in "$@"; do
    case "$a" in
      *Field=instanceType,Value=*) itype=${a##*Value=} ;;
    esac
  done
  cat "$STUB_FIXTURES/pricing-$itype.json"
  exit 0
fi
[ "$1" = ec2 ] || {
  echo "stub aws: unexpected service $1" >&2
  exit 1
}
case "$2" in
  describe-instances) cat "$STUB_FIXTURES/instances.json" ;;
  describe-spot-price-history)
    prev=
    itype=
    for a in "$@"; do
      if [ "$prev" = --instance-types ]; then itype=$a; fi
      prev=$a
    done
    cat "$STUB_FIXTURES/spot-$itype.json"
    ;;
  describe-images)
    if [ -e "$STUB_FIXTURES/registered" ]; then
      cat "$STUB_FIXTURES/images-after-register.json"
    else
      cat "$STUB_FIXTURES/images.json"
    fi
    ;;
  describe-security-groups) cat "$STUB_FIXTURES/security-groups.json" ;;
  run-instances)
    prev=
    userdata=
    for a in "$@"; do
      if [ "$prev" = --user-data ]; then userdata=${a#file://}; fi
      prev=$a
    done
    cp "$userdata" "$STUB_FIXTURES/user-data.seen" || exit 1
    stat -c %a "$userdata" >"$STUB_FIXTURES/user-data.mode"
    echo i-0launched00000001
    ;;
  register-image)
    : >"$STUB_FIXTURES/registered"
    echo ami-registered0000004
    ;;
  deregister-image | delete-snapshot) : ;;
  wait) : ;;
  terminate-instances) echo '{"TerminatingInstances":[]}' ;;
  *)
    echo "stub aws: unexpected ec2 subcommand $2" >&2
    exit 1
    ;;
esac
AWSSTUB

write_stub nix <<'NIXSTUB'
[ -e "$STUB_FIXTURES/fail-nix-$1" ] && {
  echo "stub nix: injected failure for $1" >&2
  exit 1
}
case "$1" in
  eval) cat "$STUB_FIXTURES/classes.json" ;;
  build)
    case "$*" in
      *'#ec2-base-image'*)
        [ -e "$STUB_FIXTURES/fail-nix-image" ] && {
          echo "stub nix: injected failure for the image" >&2
          exit 1
        }
        echo "$STUB_FIXTURES/image"
        ;;
      *)
        attr=
        for a in "$@"; do
          case "$a" in
            *'#nixosConfigurations.ec2-'*)
              attr=${a#*nixosConfigurations.ec2-}
              attr=${attr%%.config*}
              ;;
          esac
        done
        echo "/nix/store/fixture-toplevel-$attr"
        ;;
    esac
    ;;
  copy) printf '%s\n' "${NIX_SSHOPTS:-}" >"$STUB_FIXTURES/nix-sshopts.seen" ;;
  *)
    echo "stub nix: unexpected subcommand $1" >&2
    exit 1
    ;;
esac
NIXSTUB

# curl answers by URL. Its config arrives on stdin, so the credentials and the
# bearer token must be there and never on argv.
write_stub curl <<'CURLSTUB'
cfg=$(cat)
case "$*" in
  *api.tailscale.com/api/v2/oauth/token*)
    case "$cfg" in
      *'client_id=TS-CLIENT-STUB'*'client_secret=TS-SECRET-STUB-3c8d'*) ;;
      *)
        echo "stub curl: bad OAuth client" >&2
        exit 22
        ;;
    esac
    echo '{"access_token":"TOKEN-STUB-4b1e"}'
    ;;
  *api.tailscale.com/api/v2/tailnet/-/keys*)
    case "$cfg" in
      *'Authorization: Bearer TOKEN-STUB-4b1e'*) ;;
      *)
        echo "stub curl: bad bearer token" >&2
        exit 22
        ;;
    esac
    echo '{"key":"tskey-auth-STUB-AUTHKEY-9e2b"}'
    ;;
  *)
    echo "stub curl: unexpected URL" >&2
    exit 6
    ;;
esac
CURLSTUB

# ssh fails for the step named by fail-ssh-<step>: probe (the true readiness
# check), nix-env, or switch.
write_stub ssh <<'SSHSTUB'
case "$*" in
  *nix-env*) step=nix-env ;;
  *switch-to-configuration*) step=switch ;;
  *) step=probe ;;
esac
[ -e "$STUB_FIXTURES/fail-ssh-$step" ] && {
  echo "ssh: injected failure ($step)" >&2
  exit 255
}
exit 0
SSHSTUB

write_stub coldsnap <<'COLDSTUB'
[ -e "$STUB_FIXTURES/fail-coldsnap" ] && {
  echo "stub coldsnap: injected failure" >&2
  exit 1
}
echo snap-0feed00000000001
COLDSTUB

cat >"$STUB_FIXTURES/classes.json" <<'FIXTURE'
{"commonframe-gate":{"instanceType":"c8a.4xlarge","diskGb":80,"spot":true,"idleMinutes":60,"maxHours":24},"muniment-runner":{"instanceType":"m8a.2xlarge","diskGb":200,"spot":false,"idleMinutes":30,"maxHours":12}}
FIXTURE

t_running=$(date -u -d '210 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
t_pending=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
t_old=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
cat >"$STUB_FIXTURES/instances.json" <<FIXTURE
{"Reservations":[{"Instances":[
  {"InstanceId":"i-0fixture00000001","InstanceType":"c8a.4xlarge","State":{"Name":"running"},"LaunchTime":"$t_running","InstanceLifecycle":"spot","Placement":{"AvailabilityZone":"us-west-2a"},"Tags":[{"Key":"Name","Value":"commonframe-gate-a1b"},{"Key":"fleet","Value":"ec2"},{"Key":"fleet-class","Value":"commonframe-gate"}]},
  {"InstanceId":"i-0fixture00000002","InstanceType":"m8a.large","State":{"Name":"pending"},"LaunchTime":"$t_pending","Placement":{"AvailabilityZone":"us-west-2b"},"Tags":[{"Key":"Name","Value":"ec2-x9z"},{"Key":"fleet","Value":"ec2"},{"Key":"fleet-class","Value":"adhoc"}]},
  {"InstanceId":"i-0fixture00000003","InstanceType":"c8a.2xlarge","State":{"Name":"terminated"},"LaunchTime":"$t_old","Placement":{"AvailabilityZone":"us-west-2a"},"Tags":[{"Key":"Name","Value":"old-box"},{"Key":"fleet","Value":"ec2"}]},
  {"InstanceId":"i-0fixture00000004","InstanceType":"t3.micro","State":{"Name":"running"},"LaunchTime":"$t_running","Placement":{"AvailabilityZone":"us-west-2a"},"Tags":[{"Key":"Name","Value":"unrelated"}]}
]}]}
FIXTURE

cat >"$STUB_FIXTURES/pricing-c8a.4xlarge.json" <<'FIXTURE'
{"PriceList":["{\"terms\":{\"OnDemand\":{\"X\":{\"priceDimensions\":{\"Y\":{\"pricePerUnit\":{\"USD\":\"0.9120000000\"}}}}}}}"]}
FIXTURE
cat >"$STUB_FIXTURES/pricing-m8a.large.json" <<'FIXTURE'
{"PriceList":["{\"terms\":{\"OnDemand\":{\"X\":{\"priceDimensions\":{\"Y\":{\"pricePerUnit\":{\"USD\":\"0.1000000000\"}}}}}}}"]}
FIXTURE
cat >"$STUB_FIXTURES/spot-c8a.4xlarge.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T09:00:00+00:00","SpotPrice":"0.2100","AvailabilityZone":"us-west-2a"},{"Timestamp":"2026-10-27T08:00:00+00:00","SpotPrice":"0.1900","AvailabilityZone":"us-west-2a"}]}
FIXTURE
cat >"$STUB_FIXTURES/spot-m8a.large.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T07:00:00+00:00","SpotPrice":"0.0450","AvailabilityZone":"us-west-2b"}]}
FIXTURE

# Base AMI lists. images.json is what describe-images returns before a rebuild;
# images-after-register.json is what it returns once the stub register-image has
# run, and use_images sets both from the named fixtures.
cat >"$STUB_FIXTURES/images-full.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-older00000001","CreationDate":"2026-09-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-previous"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000001"}}]},
{"ImageId":"ami-newest00000002","CreationDate":"2026-10-20T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000002"}}]}
]}
FIXTURE
echo '{"Images":[]}' >"$STUB_FIXTURES/images-none.json"
# The oldest AMI already carries the base toplevel, so a match on any AMI but
# the newest must not count.
cat >"$STUB_FIXTURES/images-stale.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-oldest000000001","CreationDate":"2026-08-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000011"}}]},
{"ImageId":"ami-middle00000002","CreationDate":"2026-09-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-middle"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000012"}}]},
{"ImageId":"ami-latest00000003","CreationDate":"2026-10-20T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-latest"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000013"}}]}
]}
FIXTURE
cat >"$STUB_FIXTURES/images-registered.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-oldest000000001","CreationDate":"2026-08-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000011"}}]},
{"ImageId":"ami-middle00000002","CreationDate":"2026-09-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-middle"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000012"}}]},
{"ImageId":"ami-latest00000003","CreationDate":"2026-10-20T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-latest"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000013"}}]},
{"ImageId":"ami-registered0000004","CreationDate":"2026-10-27T09:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0feed00000000001"}}]}
]}
FIXTURE
cat >"$STUB_FIXTURES/images-registered-only.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-registered0000004","CreationDate":"2026-10-27T09:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0feed00000000001"}}]}
]}
FIXTURE
# The image fixture: nixpkgs writes image-info.json with an absolute .file.
mkdir -p "$STUB_FIXTURES/image/nix-support"
printf 'raw disk fixture\n' >"$STUB_FIXTURES/nixos.raw"
printf '{"boot_mode":"legacy-bios","file":"%s"}\n' "$STUB_FIXTURES/nixos.raw" \
  >"$STUB_FIXTURES/image/nix-support/image-info.json"
cat >"$STUB_FIXTURES/security-groups-full.json" <<'FIXTURE'
{"SecurityGroups":[{"GroupId":"sg-0fixture0000001","GroupName":"ec2-fleet"}]}
FIXTURE
cp "$STUB_FIXTURES/security-groups-full.json" "$STUB_FIXTURES/security-groups.json"
echo '{"SecurityGroups":[]}' >"$STUB_FIXTURES/security-groups-none.json"

printf 'AWS_ACCESS_KEY_ID=AKIASTUBKEY0001\nAWS_SECRET_ACCESS_KEY=%s\n' "$SECRET" >"$ENV_FILE"
printf 'TS_API_CLIENT_ID=TS-CLIENT-STUB\nTS_API_CLIENT_SECRET=%s\n' "$TS_SECRET" >"$TS_ENV_FILE"

# run <ec2 args...>: runs the launcher, sets STATUS/OUT/ERR, resets the call log.
run() {
  : >"$STUB_LOG"
  rm -f "$STUB_FIXTURES/user-data.seen" "$STUB_FIXTURES/user-data.mode" "$STUB_FIXTURES/nix-sshopts.seen" \
    "$STUB_FIXTURES/registered"
  if "$EC2" "$@" >"$OUT" 2>"$ERR"; then
    STATUS=0
  else
    STATUS=$?
  fi
  for secret in "$SECRET" "$TS_SECRET" "$TOKEN" "$AUTHKEY"; do
    if grep -F -q -- "$secret" "$OUT" "$ERR" "$STUB_LOG"; then
      fail "secret value appeared in launcher output or a stub's argv ($*)"
    fi
  done
  if [ "$expect_rebuild" != yes ] &&
    grep -E -q '^coldsnap |^aws ec2 (register-image|deregister-image|delete-snapshot|wait image-available) |ec2-base-image' "$STUB_LOG"; then
    fail "launcher built, uploaded, registered or pruned an image when none was expected ($*)"
  fi
  if [ "$1" != up ] && grep -E -q '^(curl|ssh) ' "$STUB_LOG"; then
    fail "launcher called a stub that must not run ($*)"
  fi
  if [ -n "$(ls -A "$TMPDIR")" ]; then
    fail "launcher left a temp file behind ($*)"
  fi
}

expect_status() {
  [ "$STATUS" -eq "$1" ] || fail "$2: exit $STATUS, want $1: $(cat "$ERR")"
}
expect_nonzero() {
  [ "$STATUS" -ne 0 ] || fail "$1: exit 0, want nonzero"
}
expect_out() {
  grep -E -q -- "$1" "$OUT" || fail "$2: stdout has no line matching /$1/"
}
expect_no_out() {
  if grep -E -q -- "$1" "$OUT"; then fail "$2: stdout has a line matching /$1/"; fi
}
expect_err() {
  grep -E -q -- "$1" "$ERR" || fail "$2: stderr has no line matching /$1/"
}
expect_log() {
  grep -E -q -- "$1" "$STUB_LOG" || fail "$2: no stub call matching /$1/"
}
expect_no_log() {
  if grep -E -q -- "$1" "$STUB_LOG"; then fail "$2: unexpected stub call matching /$1/"; fi
}
# expect_fixed / expect_no_fixed match a literal substring of the call log.
expect_fixed() {
  grep -F -q -- "$1" "$STUB_LOG" || fail "$2: no stub call containing: $1"
}
expect_no_fixed() {
  if grep -F -q -- "$1" "$STUB_LOG"; then fail "$2: unexpected stub call containing: $1"; fi
}
# expect_order <desc> <pattern>...: each literal pattern first appears in the
# call log after the one before it.
expect_order() {
  local desc=$1 prev=0 cur pat
  shift
  for pat in "$@"; do
    cur=$(grep -F -n -m1 -- "$pat" "$STUB_LOG" | cut -d: -f1)
    if [ -z "$cur" ] || [ "$cur" -le "$prev" ]; then
      fail "$desc: '$pat' is missing or out of order"
      return
    fi
    prev=$cur
  done
}
# expect_terminated <desc>: exactly one terminate for the launched instance.
expect_terminated() {
  local count
  count=$(grep -c -F -- 'terminate-instances --instance-ids i-0launched00000001' "$STUB_LOG")
  [ "$count" -eq 1 ] || fail "$1: want one terminate-instances for i-0launched00000001, got $count"
}
# expect_userdata <desc> <name>: the user-data run-instances received carried
# the name and auth key, was mode 0600, and its file was removed.
expect_userdata() {
  local seen="$STUB_FIXTURES/user-data.seen"
  if [ ! -f "$seen" ]; then
    fail "$1: run-instances received no user-data file"
    return
  fi
  grep -x -F -q "EC2_FLEET_NAME=$2" "$seen" || fail "$1: user-data lacks EC2_FLEET_NAME=$2"
  grep -x -F -q "EC2_FLEET_TS_AUTHKEY=$AUTHKEY" "$seen" || fail "$1: user-data lacks the auth key line"
  [ "$(wc -l <"$seen")" -eq 2 ] || fail "$1: user-data is not exactly two lines"
  [ "$(cat "$STUB_FIXTURES/user-data.mode")" = 600 ] || fail "$1: user-data file was not mode 600"
}
inject() {
  : >"$STUB_FIXTURES/fail-$1"
}
clear_faults() {
  rm -f "$STUB_FIXTURES"/fail-*
}
# use_images <before> <after>: the describe-images lists from the named fixtures,
# before a rebuild and after the new AMI is registered.
use_images() {
  cp "$STUB_FIXTURES/$1.json" "$STUB_FIXTURES/images.json" || exit 1
  cp "$STUB_FIXTURES/$2.json" "$STUB_FIXTURES/images-after-register.json" || exit 1
}
# rebuild_run <ec2 args...>: runs the launcher in a case where an image rebuild
# is expected, which alone allows coldsnap and the image calls.
rebuild_run() {
  expect_rebuild=yes
  run "$@"
  expect_rebuild=no
}
# expect_rebuilt <desc> <toplevel basename>: the rebuild built the image, uploaded
# its file tagged fleet=ec2-base, registered it with the fleet tags and the
# image settings, waited for it, and ran the launch from the new AMI, all before
# any Tailscale call.
expect_rebuilt() {
  local desc=$1 tl=$2
  expect_fixed "nix build --no-link --print-out-paths /fixture/flake#ec2-base-image" "$desc builds the base image"
  expect_fixed "coldsnap --region us-west-2 upload --wait --no-progress --tag Key=fleet,Value=ec2-base $STUB_FIXTURES/nixos.raw" "$desc uploads the image file tagged fleet=ec2-base"
  expect_fixed "aws ec2 register-image" "$desc registers the snapshot"
  expect_fixed "--name ec2-base-$tl-" "$desc names the AMI from the toplevel"
  expect_fixed "--architecture x86_64" "$desc registers x86_64"
  expect_fixed "--virtualization-type hvm" "$desc registers hvm"
  expect_fixed "--root-device-name /dev/xvda" "$desc sets the root device name"
  expect_fixed "--ena-support" "$desc enables ENA"
  expect_fixed "--boot-mode legacy-bios" "$desc registers legacy-bios"
  expect_fixed "--block-device-mappings DeviceName=/dev/xvda,Ebs={SnapshotId=snap-0feed00000000001,VolumeType=gp3,DeleteOnTermination=true}" "$desc maps the uploaded snapshot to /dev/xvda"
  expect_fixed "--tag-specifications ResourceType=image,Tags=[{Key=fleet,Value=ec2-base},{Key=fleet-toplevel,Value=$tl}]" "$desc tags the AMI with the toplevel"
  expect_fixed "aws ec2 wait image-available --image-ids ami-registered0000004" "$desc waits for the new AMI"
  expect_fixed "--image-id ami-registered0000004" "$desc launches the new AMI"
  expect_order "$desc orders the image steps before the Tailscale call" \
    "nix build --no-link --print-out-paths /fixture/flake#ec2-base-image" \
    "coldsnap --region us-west-2 upload" \
    "aws ec2 register-image" \
    "aws ec2 wait image-available" \
    "api/v2/oauth/token" \
    "aws ec2 run-instances"
}

# help: needs no credentials, reads classes from the flake, lists rules.
unset EC2_FLEET_AWS_ENV_FILE
run help
expect_status 0 "help"
expect_out 'commonframe-gate .*c8a\.4xlarge' "help names commonframe-gate with its type"
expect_out 'muniment-runner .*m8a\.2xlarge' "help names muniment-runner with its type"
expect_out 'idleMinutes' "help states the idle rule"
expect_out 'maxHours' "help states the uptime rule"
expect_out 'load average' "help states the load rule"
expect_out 'ssh session' "help states the ssh rule"
expect_out 'busyCommand' "help states the busyCommand rule"
expect_out '128 vCPU' "help states the warden vCPU cap"
expect_out 'fleet-max-hours' "help states the warden age rule"
expect_out 'ec2 up <class>' "help lists up <class>"
expect_out 'ec2 up --type' "help lists up --type"
expect_out -- '--spot' "help lists --spot"
expect_out 'ec2 ls' "help lists ls"
expect_out 'ec2 down <name>' "help lists down"
expect_out 'ec2 help' "help lists help"
expect_log 'nix eval --json /fixture/flake#ec2Classes' "help reads classes from the flake"

# ls: every pending/running fleet=ec2 box, one row each, with prices.
export EC2_FLEET_AWS_ENV_FILE=$ENV_FILE
run ls
expect_status 0 "ls"
expect_out '^NAME +CLASS +TYPE +SPOT +AGE +ON-DEMAND/HR +SPOT/HR$' "ls header"
expect_out '^commonframe-gate-a1b +commonframe-gate +c8a\.4xlarge +yes +3h3[0-9]m +0\.9120000000 +0\.2100$' "ls row for the spot box with newest spot price"
expect_out '^ec2-x9z +adhoc +m8a\.large +no +0h0[3-9]m +0\.1000000000 +0\.0450$' "ls row for the on-demand pending box"
expect_no_out 'old-box|unrelated|i-0fixture00000003|i-0fixture00000004' "ls omits terminated and non-fleet boxes"
expect_log 'ec2 describe-instances' "ls lists instances"
expect_log 'pricing get-products --region us-east-1 --service-code AmazonEC2' "ls asks pricing in us-east-1"
expect_log 'Field=instanceType,Value=c8a\.4xlarge' "ls prices the spot box type"
expect_log 'Field=regionCode,Value=us-west-2' "ls prices in us-west-2"
expect_log 'Field=operatingSystem,Value=Linux' "ls prices Linux"
expect_log 'Field=tenancy,Value=Shared' "ls prices shared tenancy"
expect_log 'Field=preInstalledSw,Value=NA' "ls prices without preinstalled software"
expect_log 'Field=capacitystatus,Value=Used' "ls prices used capacity"
expect_log 'describe-spot-price-history .*--instance-types c8a\.4xlarge' "ls asks spot price for the box type"
expect_log 'describe-spot-price-history .*--availability-zone us-west-2a' "ls asks spot price in the box zone"
expect_log 'describe-spot-price-history .*Linux/UNIX' "ls asks Linux/UNIX spot price"
expect_no_log 'terminate-instances' "ls terminates nothing"

# ls exits nonzero when any AWS call it depends on fails.
for failing in ec2-describe-instances pricing-get-products ec2-describe-spot-price-history; do
  : >"$STUB_FIXTURES/fail-$failing"
  run ls
  expect_nonzero "ls with $failing failing"
  rm -f "$STUB_FIXTURES/fail-$failing"
done

# ls and down refuse to run without credentials, and call no AWS API.
unset EC2_FLEET_AWS_ENV_FILE
run ls
expect_nonzero "ls without EC2_FLEET_AWS_ENV_FILE"
expect_no_log '.' "ls without EC2_FLEET_AWS_ENV_FILE makes no stub call"
run down commonframe-gate-a1b
expect_nonzero "down without EC2_FLEET_AWS_ENV_FILE"
expect_no_log '.' "down without EC2_FLEET_AWS_ENV_FILE makes no stub call"
export EC2_FLEET_AWS_ENV_FILE=$work/missing.env
run ls
expect_nonzero "ls with a missing env file"
expect_no_log '.' "ls with a missing env file makes no stub call"

# down: terminates the one matching fleet box, and nothing else.
export EC2_FLEET_AWS_ENV_FILE=$ENV_FILE
run down commonframe-gate-a1b
expect_status 0 "down"
expect_log 'ec2 terminate-instances --instance-ids i-0fixture00000001$' "down terminates the matched instance id"
if [ "$(grep -c 'terminate-instances' "$STUB_LOG")" -ne 1 ]; then
  fail "down made more than one terminate-instances call"
fi

run down no-such-box
expect_nonzero "down of an unknown name"
expect_err 'no-such-box' "down of an unknown name names the box"
expect_no_log 'terminate-instances' "down of an unknown name terminates nothing"

run down old-box
expect_nonzero "down of a terminated box"
expect_no_log 'terminate-instances' "down of a terminated box terminates nothing"

# up: bad arguments are refused before any AWS, Tailscale, ssh or nix build call.
export EC2_FLEET_AWS_ENV_FILE=$ENV_FILE
export EC2_FLEET_TS_ENV_FILE=$TS_ENV_FILE
unset EC2_FLEET_READY_TIMEOUT
for args in "" "--type c8a.large" "--type c8a.large --disk 0" "--type c8a.large --disk 20x" \
  "commonframe-gate --spot" "commonframe-gate extra" "--type c8a.large --disk 20 commonframe-gate"; do
  run up $args
  expect_nonzero "up $args"
  expect_no_log '^(aws|curl|ssh) |nix build' "up $args calls no AWS, Tailscale, ssh or nix build"
done

run up nosuch-class
expect_nonzero "up with an unknown class"
expect_err 'unknown class: nosuch-class' "up names the unknown class"
expect_no_log '^(aws|curl|ssh) |nix build' "up with an unknown class calls no AWS, Tailscale, ssh or nix build"

unset EC2_FLEET_TS_ENV_FILE
run up commonframe-gate
expect_nonzero "up without EC2_FLEET_TS_ENV_FILE"
expect_no_log '^(aws|curl|ssh) |run-instances' "up without EC2_FLEET_TS_ENV_FILE launches nothing"
export EC2_FLEET_TS_ENV_FILE=$TS_ENV_FILE

unset EC2_FLEET_AWS_ENV_FILE
run up commonframe-gate
expect_nonzero "up without EC2_FLEET_AWS_ENV_FILE"
expect_no_log '^(aws|curl|ssh) ' "up without EC2_FLEET_AWS_ENV_FILE calls no AWS or Tailscale API"
export EC2_FLEET_AWS_ENV_FILE=$ENV_FILE

export EC2_FLEET_READY_TIMEOUT=soon
run up --type c8a.large --disk 20
expect_nonzero "up with a non-numeric EC2_FLEET_READY_TIMEOUT"
expect_no_fixed 'run-instances' "up with a non-numeric EC2_FLEET_READY_TIMEOUT launches nothing"
unset EC2_FLEET_READY_TIMEOUT

# up with no base AMI: the image is built, registered and launched from, and
# nothing is pruned because the new AMI is the only one.
use_images images-none images-registered-only
rebuild_run up commonframe-gate
expect_status 0 "up with no base AMI"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up with no base AMI prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_rebuilt "up with no base AMI" fixture-toplevel-base
expect_userdata "up with no base AMI" "$name"
expect_no_fixed "deregister-image" "up with no base AMI deregisters nothing"
expect_no_fixed "delete-snapshot" "up with no base AMI deletes no snapshot"
expect_no_fixed "terminate-instances" "up with no base AMI terminates nothing on success"

# up on a toplevel mismatch: the newest AMI tags a different toplevel, so the
# image is rebuilt. The two oldest base AMIs are deregistered and their
# snapshots deleted; the newest AMI and the previous newest are kept.
use_images images-stale images-registered
rebuild_run up commonframe-gate
expect_status 0 "up on a toplevel mismatch"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up on a toplevel mismatch prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_rebuilt "up on a toplevel mismatch" fixture-toplevel-base
expect_userdata "up on a toplevel mismatch" "$name"
expect_fixed "aws ec2 deregister-image --image-id ami-middle00000002" "up on a mismatch deregisters the second-oldest base AMI"
expect_fixed "aws ec2 deregister-image --image-id ami-oldest000000001" "up on a mismatch deregisters the oldest base AMI"
expect_no_fixed "deregister-image --image-id ami-latest00000003" "up on a mismatch keeps the previous newest AMI"
expect_no_fixed "deregister-image --image-id ami-registered0000004" "up on a mismatch keeps the new AMI"
expect_fixed "aws ec2 delete-snapshot --snapshot-id snap-0a1d00000000012" "up on a mismatch deletes the snapshot of the second-oldest AMI"
expect_fixed "aws ec2 delete-snapshot --snapshot-id snap-0a1d00000000011" "up on a mismatch deletes the snapshot of the oldest AMI"
expect_no_fixed "delete-snapshot --snapshot-id snap-0a1d00000000013" "up on a mismatch keeps the snapshot of the previous newest AMI"
expect_no_fixed "delete-snapshot --snapshot-id snap-0feed00000000001" "up on a mismatch keeps the snapshot of the new AMI"
expect_order "up on a mismatch prunes after the new AMI is available and before launch" \
  "aws ec2 wait image-available" \
  "aws ec2 deregister-image --image-id ami-middle00000002" \
  "aws ec2 delete-snapshot --snapshot-id snap-0a1d00000000012" \
  "aws ec2 deregister-image --image-id ami-oldest000000001" \
  "aws ec2 delete-snapshot --snapshot-id snap-0a1d00000000011" \
  "aws ec2 run-instances"

# ad-hoc up on a mismatch rebuilds the same way and launches the new AMI.
use_images images-stale images-registered
rebuild_run up --type m8a.large --disk 20
expect_status 0 "ad-hoc up on a toplevel mismatch"
expect_rebuilt "ad-hoc up on a toplevel mismatch" fixture-toplevel-base
expect_no_fixed "nix copy" "ad-hoc up on a mismatch copies nothing"

# A failure in the image build, upload, register or AMI wait stops before
# Tailscale and run-instances, and exits nonzero. A failure in the prune also
# stops the launch. A register failure deletes the snapshot it uploaded, since
# no AMI uses it.
use_images images-stale images-registered
for fault in nix-image coldsnap ec2-register-image ec2-wait ec2-deregister-image ec2-delete-snapshot; do
  inject "$fault"
  rebuild_run up commonframe-gate
  expect_nonzero "up on a mismatch with $fault failing"
  expect_no_fixed "run-instances" "up on a mismatch with $fault failing launches nothing"
  expect_no_fixed "api/v2" "up on a mismatch with $fault failing asks Tailscale nothing"
  expect_no_fixed "wait instance-running" "up on a mismatch with $fault failing waits for no instance"
  expect_no_fixed "terminate-instances" "up on a mismatch with $fault failing terminates nothing"
  case "$fault" in
    nix-image) expect_no_fixed "coldsnap" "up with nix-image failing uploads nothing" ;;
    coldsnap) expect_no_fixed "register-image" "up with coldsnap failing registers nothing" ;;
    ec2-register-image)
      expect_fixed "aws ec2 delete-snapshot --snapshot-id snap-0feed00000000001" "up with register-image failing deletes the unused snapshot"
      ;;
  esac
  clear_faults
done

# up: a missing security group or AWS lookup stops before launch.
use_images images-full images-registered-only

cp "$STUB_FIXTURES/security-groups-none.json" "$STUB_FIXTURES/security-groups.json"
run up commonframe-gate
expect_nonzero "up with no ec2-sg security group"
expect_err 'no ec2-sg security group' "up with no security group names the missing group"
expect_no_fixed 'run-instances' "up with no security group launches nothing"
cp "$STUB_FIXTURES/security-groups-full.json" "$STUB_FIXTURES/security-groups.json"

inject ec2-describe-images
run up commonframe-gate
expect_nonzero "up with describe-images failing"
expect_no_fixed 'run-instances' "up with describe-images failing launches nothing"
clear_faults

inject nix-build
run up commonframe-gate
expect_nonzero "up with nix build failing"
expect_no_fixed 'run-instances' "up with nix build failing launches nothing"
expect_no_fixed 'api/v2' "up with nix build failing asks Tailscale nothing"
clear_faults

# up commonframe-gate: spot class, newest AMI, tailnet key, deploy and switch.
use_images images-full images-registered-only
run up commonframe-gate
expect_status 0 "up commonframe-gate"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up commonframe-gate prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
TL=/nix/store/fixture-toplevel-commonframe-gate

expect_fixed "nix build --no-link --print-out-paths /fixture/flake#nixosConfigurations.ec2-commonframe-gate.config.system.build.toplevel" "up builds the class toplevel"
expect_fixed "nix build --no-link --print-out-paths /fixture/flake#nixosConfigurations.ec2-base.config.system.build.toplevel" "up builds the base toplevel to compare"
expect_no_fixed "ec2-base-image" "up on a matching AMI builds no base image"
expect_no_fixed "aws ec2 register-image" "up on a matching AMI registers nothing"
expect_fixed "curl --config - -fsS https://api.tailscale.com/api/v2/oauth/token" "up asks Tailscale for an OAuth token"
expect_fixed "-d $BODY https://api.tailscale.com/api/v2/tailnet/-/keys" "up asks for a key with the exact body"
expect_fixed "aws ec2 run-instances" "up calls run-instances"
expect_fixed "--image-id ami-newest00000002" "up launches the newest base AMI"
expect_no_fixed "ami-older00000001" "up does not launch the older base AMI"
expect_fixed "--instance-type c8a.4xlarge" "up sets the class instance type"
expect_fixed "--block-device-mappings DeviceName=/dev/xvda,Ebs={VolumeSize=80,VolumeType=gp3,DeleteOnTermination=true}" "up sizes the gp3 root volume and deletes it on termination"
expect_fixed "--network-interfaces DeviceIndex=0,AssociatePublicIpAddress=true,Groups=sg-0fixture0000001" "up attaches the ec2-fleet group with a public address"
expect_fixed "--metadata-options HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" "up requires IMDSv2 with hop limit 1"
expect_fixed "--instance-initiated-shutdown-behavior terminate" "up terminates on shutdown"
expect_fixed "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=fleet,Value=ec2},{Key=fleet-class,Value=commonframe-gate},{Key=fleet-max-hours,Value=24}]" "up tags the instance"
expect_fixed "ResourceType=volume,Tags=[{Key=fleet,Value=ec2},{Key=Name,Value=$name}]" "up tags the volume"
expect_fixed "--instance-market-options MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}" "up requests one-time spot with terminate on interruption"
expect_fixed "--user-data file://" "up passes user-data as a file"
expect_no_fixed "--key-name" "up launches with no key pair"
expect_no_fixed "--iam-instance-profile" "up launches with no instance profile"
expect_userdata "up commonframe-gate" "$name"
expect_order "up orders the launch and deploy steps" \
  "api/v2/oauth/token" \
  "api/v2/tailnet/-/keys" \
  "aws ec2 run-instances" \
  "aws ec2 wait instance-running" \
  "joshsymonds@$name true" \
  "nix copy --substitute-on-destination --to ssh-ng://joshsymonds@$name $TL" \
  "joshsymonds@$name sudo nix-env -p /nix/var/nix/profiles/system --set $TL" \
  "joshsymonds@$name sudo $TL/bin/switch-to-configuration switch"
expect_fixed "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$XDG_STATE_HOME/ec2-fleet/known_hosts" "up sets the ssh host-key options"
[ -d "$XDG_STATE_HOME/ec2-fleet" ] || fail "up did not create the ec2-fleet state directory"
grep -F -q "UserKnownHostsFile=$XDG_STATE_HOME/ec2-fleet/known_hosts" "$STUB_FIXTURES/nix-sshopts.seen" || fail "up did not pass the host-key options to nix copy"
expect_no_fixed "terminate-instances" "up commonframe-gate terminates nothing on success"

# up --type --disk --spot: ad-hoc spot box, no deploy.
run up --type c8a.large --disk 40 --spot
expect_status 0 "ad-hoc spot up"
expect_out '^ec2-[a-z0-9]{3} ready$' "ad-hoc spot up prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_fixed "--instance-type c8a.large" "ad-hoc up sets the instance type"
expect_fixed "--block-device-mappings DeviceName=/dev/xvda,Ebs={VolumeSize=40,VolumeType=gp3,DeleteOnTermination=true}" "ad-hoc up sizes the root volume from --disk"
expect_fixed "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=fleet,Value=ec2},{Key=fleet-class,Value=adhoc},{Key=fleet-max-hours,Value=24}]" "ad-hoc up tags an adhoc instance with 24 max hours"
expect_fixed "--instance-market-options MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}" "ad-hoc --spot requests spot"
expect_fixed "joshsymonds@$name true" "ad-hoc up waits for ssh"
expect_fixed "nix build --no-link --print-out-paths /fixture/flake#nixosConfigurations.ec2-base.config.system.build.toplevel" "ad-hoc up builds the base toplevel to compare"
[ "$(grep -c '^nix build' "$STUB_LOG")" -eq 1 ] || fail "ad-hoc up builds more than the base toplevel"
expect_no_fixed "nix copy" "ad-hoc up copies nothing"
expect_no_fixed "nix-env" "ad-hoc up sets no profile"
expect_no_fixed "switch-to-configuration" "ad-hoc up switches nothing"
expect_no_fixed "nix eval" "ad-hoc up reads no class data"
expect_no_fixed "terminate-instances" "ad-hoc up terminates nothing on success"
expect_userdata "ad-hoc spot up" "$name"

# up --type --disk without --spot: on-demand, no market options.
run up --type m8a.large --disk 20
expect_status 0 "ad-hoc on-demand up"
expect_out '^ec2-[a-z0-9]{3} ready$' "ad-hoc on-demand up prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_fixed "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=fleet,Value=ec2},{Key=fleet-class,Value=adhoc},{Key=fleet-max-hours,Value=24}]" "ad-hoc on-demand up tags the instance"
expect_no_fixed "--instance-market-options" "ad-hoc on-demand up requests no spot"

# up muniment-runner: on-demand class with its own disk and max hours.
run up muniment-runner
expect_status 0 "up muniment-runner"
expect_out '^muniment-runner-[a-z0-9]{3} ready$' "up muniment-runner prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_fixed "--instance-type m8a.2xlarge" "up muniment-runner sets its instance type"
expect_fixed "Ebs={VolumeSize=200,VolumeType=gp3,DeleteOnTermination=true}" "up muniment-runner sizes its root volume"
expect_fixed "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=fleet,Value=ec2},{Key=fleet-class,Value=muniment-runner},{Key=fleet-max-hours,Value=12}]" "up muniment-runner tags its max hours"
expect_no_fixed "--instance-market-options" "up muniment-runner requests no spot"
expect_fixed "nix copy --substitute-on-destination --to ssh-ng://joshsymonds@$name /nix/store/fixture-toplevel-muniment-runner" "up muniment-runner copies its own toplevel"
expect_fixed "joshsymonds@$name sudo /nix/store/fixture-toplevel-muniment-runner/bin/switch-to-configuration switch" "up muniment-runner switches its own toplevel"

# A failure after run-instances terminates the launched instance and exits nonzero.
export EC2_FLEET_READY_TIMEOUT=0
for fault in ec2-wait ssh-probe nix-copy ssh-nix-env ssh-switch; do
  inject "$fault"
  run up commonframe-gate
  expect_nonzero "up commonframe-gate with $fault failing"
  expect_terminated "up commonframe-gate with $fault failing"
  case "$fault" in
    ec2-wait | ssh-probe) expect_no_fixed "nix copy" "up with $fault failing does not copy" ;;
    nix-copy) expect_no_fixed "nix-env" "up with nix-copy failing does not set the profile" ;;
    ssh-nix-env) expect_no_fixed "switch-to-configuration" "up with ssh-nix-env failing does not switch" ;;
  esac
  clear_faults
done

for fault in ec2-wait ssh-probe; do
  inject "$fault"
  run up --type c8a.large --disk 40 --spot
  expect_nonzero "ad-hoc up with $fault failing"
  expect_terminated "ad-hoc up with $fault failing"
  clear_faults
done
unset EC2_FLEET_READY_TIMEOUT

# A run-instances failure launched nothing, so there is nothing to terminate.
inject ec2-run-instances
run up commonframe-gate
expect_nonzero "up with run-instances failing"
expect_no_fixed "wait instance-running" "up with run-instances failing waits for nothing"
expect_no_fixed "terminate-instances" "up with run-instances failing terminates nothing"
clear_faults

if [ "$failures" -ne 0 ]; then
  echo "ec2 stubbed test: $failures check(s) failed" >&2
  exit 1
fi
echo "ec2 stubbed test: all checks passed"
