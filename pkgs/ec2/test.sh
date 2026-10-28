#!/usr/bin/env bash
# Stubbed test for the ec2 launcher. Usage: test.sh <path-to-ec2-binary>.
# The launcher runs with stub aws, nix, curl and ssh on PATH; each stub appends
# its argv to $STUB_LOG. coldsnap is a stub that must never run. No network
# access is made.
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
  describe-images) cat "$STUB_FIXTURES/images.json" ;;
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
echo "unexpected call to a stub that must not run" >&2
exit 99
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

cat >"$STUB_FIXTURES/images-full.json" <<'FIXTURE'
{"Images":[{"ImageId":"ami-older00000001","CreationDate":"2026-09-01T10:00:00.000Z"},{"ImageId":"ami-newest00000002","CreationDate":"2026-10-20T10:00:00.000Z"}]}
FIXTURE
cp "$STUB_FIXTURES/images-full.json" "$STUB_FIXTURES/images.json"
echo '{"Images":[]}' >"$STUB_FIXTURES/images-none.json"
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
  rm -f "$STUB_FIXTURES/user-data.seen" "$STUB_FIXTURES/user-data.mode" "$STUB_FIXTURES/nix-sshopts.seen"
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
  if grep -E -q '^coldsnap ' "$STUB_LOG"; then
    fail "launcher called coldsnap ($*)"
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

# up: a missing base AMI, security group or AWS lookup stops before launch.
cp "$STUB_FIXTURES/images-none.json" "$STUB_FIXTURES/images.json"
run up commonframe-gate
expect_nonzero "up with no base AMI"
expect_err 'no ec2-base AMI' "up with no base AMI names the missing AMI"
expect_no_fixed 'run-instances' "up with no base AMI launches nothing"
expect_no_fixed 'api/v2' "up with no base AMI asks Tailscale nothing"
cp "$STUB_FIXTURES/images-full.json" "$STUB_FIXTURES/images.json"

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
run up commonframe-gate
expect_status 0 "up commonframe-gate"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up commonframe-gate prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
TL=/nix/store/fixture-toplevel-commonframe-gate

expect_fixed "nix build --no-link --print-out-paths /fixture/flake#nixosConfigurations.ec2-commonframe-gate.config.system.build.toplevel" "up builds the class toplevel"
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
expect_no_fixed "nix build" "ad-hoc up builds nothing"
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
