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
STUB_REGION_LOG="$work/regions.log"
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
export STUB_LOG STUB_REGION_LOG STUB_FIXTURES
export PATH="$work/bin:$PATH"
export EC2_FLEET_FLAKE=/fixture/flake
export EC2_FLEET_LOOKUP_INTERVAL=0
export XDG_STATE_HOME="$work/state"
export TMPDIR="$work/tmp"
# The region is named only by the launcher's own calls, so a call that forgets
# its region finds none here.
unset AWS_REGION AWS_DEFAULT_REGION
mkdir -p "$work/bin" "$STUB_FIXTURES/eu-west-1" "$TMPDIR"
: >"$STUB_LOG"
: >"$STUB_REGION_LOG"

failures=0
STATUS=0
probe_signal=
run_signal=
terminate_signal=
signal_group=
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
  itype= region=
  for a in "$@"; do
    case "$a" in
      *Field=instanceType,Value=*) itype=${a##*Value=} ;;
      *Field=regionCode,Value=*) region=${a##*Value=} ;;
    esac
  done
  [ -e "$STUB_FIXTURES/fail-$region-$1-$2" ] && {
    echo "An error occurred (AccessDenied) when calling $2 in $region" >&2
    exit 255
  }
  # A price is read from the directory of the region its regionCode names.
  case "$region" in
    us-west-2) rdir=$STUB_FIXTURES ;;
    eu-west-1) rdir=$STUB_FIXTURES/eu-west-1 ;;
    *)
      echo "stub aws: pricing call with no fleet regionCode: $*" >&2
      exit 1
      ;;
  esac
  cat "$rdir/pricing-$itype.json"
  exit 0
fi
[ "$1" = ec2 ] || {
  echo "stub aws: unexpected service $1" >&2
  exit 1
}
# An ec2 call names its fleet region through AWS_REGION. Each region reads its
# own fixtures: us-west-2 the top of $STUB_FIXTURES, eu-west-1 its subdirectory.
case "${AWS_REGION:-}" in
  us-west-2) rdir=$STUB_FIXTURES ;;
  eu-west-1) rdir=$STUB_FIXTURES/eu-west-1 ;;
  *)
    echo "stub aws: ec2 call with no fleet region (AWS_REGION=${AWS_REGION:-unset}): $*" >&2
    exit 1
    ;;
esac
[ -e "$STUB_FIXTURES/fail-$AWS_REGION-$1-$2" ] && {
  echo "An error occurred (AccessDenied) when calling $2 in $AWS_REGION" >&2
  exit 255
}
printf '%s %s\n' "$AWS_REGION" "$*" >>"$STUB_REGION_LOG"
case "$2" in
  describe-instances)
    # A client-token filter answers only with the boxes recorded under that token
    # in this region; any other describe answers with the fixture fleet.
    token=
    for a in "$@"; do
      case "$a" in
        Name=client-token,Values=*) token=${a#Name=client-token,Values=} ;;
      esac
    done
    if [ -n "$token" ]; then
      if [ -e "$rdir/by-token/$token.json" ]; then
        cat "$rdir/by-token/$token.json"
      else
        echo '{"Reservations":[]}'
      fi
    else
      cat "$rdir/instances.json"
    fi
    ;;
  describe-spot-price-history)
    prev=
    itype=
    for a in "$@"; do
      if [ "$prev" = --instance-types ]; then itype=$a; fi
      prev=$a
    done
    cat "$rdir/spot-$itype.json"
    ;;
  describe-instance-type-offerings)
    itype=
    for a in "$@"; do
      case "$a" in
        Name=instance-type,Values=*) itype=${a##*Values=} ;;
      esac
    done
    cat "$rdir/offerings-$itype.json"
    ;;
  get-spot-placement-scores)
    prev=
    itype=
    for a in "$@"; do
      if [ "$prev" = --instance-types ]; then itype=$a; fi
      prev=$a
    done
    cat "$rdir/scores-$itype.json"
    ;;
  describe-images)
    if [ -e "$rdir/registered" ]; then
      cat "$rdir/images-after-register.json"
    else
      cat "$rdir/images.json"
    fi
    ;;
  describe-security-groups) cat "$rdir/security-groups.json" ;;
  run-instances)
    # hold-run-instances keeps the call running until the release file exists, so a
    # signal can arrive during it.
    [ -e "$STUB_FIXTURES/hold-run-instances" ] && {
      for _ in $(seq 1 100); do
        [ -e "$STUB_FIXTURES/release" ] && break
        sleep 0.1
      done
    }
    # no-capacity-<zone> refuses a placed launch in that zone with the capacity
    # error; other-error-<zone> refuses it with an error that is not a capacity one.
    # throttle-<spot|on-demand>-<zone> refuses a placed launch of that market in
    # that zone with a zone-scoped throttle; account-throttle refuses every launch
    # with an account-level throttle that names no zone. no-capacity-unplaced
    # refuses a launch with no placement, in the region's own directory.
    # quota-<spot|on-demand> refuses every launch of that market in that region,
    # placed or not, with the market's quota error.
    zone=
    market=on-demand
    for a in "$@"; do
      case "$a" in
        AvailabilityZone=*) zone=${a#AvailabilityZone=} ;;
        --instance-market-options) market=spot ;;
      esac
    done
    if [ -n "$zone" ] && [ -e "$rdir/no-capacity-$zone" ]; then
      echo "An error occurred (InsufficientInstanceCapacity) when calling the RunInstances operation: We currently do not have sufficient capacity in the Availability Zone you requested ($zone)." >&2
      exit 1
    fi
    if [ -z "$zone" ] && [ -e "$rdir/no-capacity-unplaced" ]; then
      echo "An error occurred (InsufficientInstanceCapacity) when calling the RunInstances operation: We currently do not have sufficient capacity for the requested instance in $AWS_REGION." >&2
      exit 1
    fi
    if [ -n "$zone" ] && [ -e "$rdir/other-error-$zone" ]; then
      echo "An error occurred (UnsupportedOperation) when calling the RunInstances operation: injected failure in $zone." >&2
      exit 1
    fi
    if [ -n "$zone" ] && [ -e "$rdir/throttle-$market-$zone" ]; then
      echo "An error occurred (RequestLimitExceeded) when calling the RunInstances operation (reached max retries: 2): Request limit exceeded. Your ec2:RunInstances request has been throttled due to an operational issue in availability zone usw2-az1. Throttling will be removed once the issue is resolved." >&2
      exit 1
    fi
    if [ -e "$rdir/quota-$market" ]; then
      if [ "$market" = spot ]; then
        echo "An error occurred (MaxSpotInstanceCountExceeded) when calling the RunInstances operation: Max spot instance count exceeded." >&2
      else
        echo "An error occurred (VcpuLimitExceeded) when calling the RunInstances operation: You have requested more vCPU capacity than your current vCPU limit of 640 allows for the instance bucket that the specified instance type belongs to." >&2
      fi
      exit 1
    fi
    # timeout-<zone> and no-id-<zone> (timeout-unplaced and no-id-unplaced for a
    # launch with no placement) start a box under the call's --client-token in the
    # region's directory, so describe-instances sees it there only. timeout-<key>
    # then times out with an unrecognised error; no-id-<key> answers with no id.
    key=${zone:-unplaced}
    if [ -e "$rdir/timeout-$key" ] || [ -e "$rdir/no-id-$key" ]; then
      prev=
      tok=
      for a in "$@"; do
        if [ "$prev" = --client-token ]; then tok=$a; fi
        prev=$a
      done
      mkdir -p "$rdir/by-token" || exit 1
      printf '%s\n' '{"Reservations":[{"Instances":[{"InstanceId":"i-0launched00000001","State":{"Name":"pending"},"Tags":[]}]}]}' >"$rdir/by-token/$tok.json" || exit 1
      if [ -e "$rdir/no-id-$key" ]; then
        exit 0
      fi
      echo "An error occurred (RequestTimeout) when calling the RunInstances operation: Request timed out." >&2
      exit 255
    fi
    if [ -e "$rdir/account-throttle" ]; then
      echo "An error occurred (RequestLimitExceeded) when calling the RunInstances operation (reached max retries: 2): Request limit exceeded." >&2
      exit 1
    fi
    # warn-run-instances makes a successful launch also write a warning to stderr.
    [ -e "$STUB_FIXTURES/warn-run-instances" ] && echo "stub aws: a warning from run-instances" >&2
    prev=
    userdata=
    for a in "$@"; do
      if [ "$prev" = --user-data ]; then userdata=${a#file://}; fi
      prev=$a
    done
    # Each call's user-data is kept as user-data.<call number>.seen; user-data.seen
    # holds the latest call's copy.
    n=$(grep -c '^aws ec2 run-instances ' "$STUB_LOG")
    cp "$userdata" "$STUB_FIXTURES/user-data.$n.seen" || exit 1
    cp "$userdata" "$STUB_FIXTURES/user-data.seen" || exit 1
    stat -c %a "$userdata" >"$STUB_FIXTURES/user-data.mode"
    echo i-0launched00000001
    ;;
  register-image)
    : >"$rdir/registered"
    case "$AWS_REGION" in
      us-west-2) echo ami-registered0000004 ;;
      eu-west-1) echo ami-irelandnew0005 ;;
    esac
    ;;
  deregister-image | delete-snapshot) : ;;
  wait)
    # running-fail-left holds how many more instance-running waits fail.
    if [ "$3" = instance-running ] && [ -e "$STUB_FIXTURES/running-fail-left" ]; then
      left=$(cat "$STUB_FIXTURES/running-fail-left")
      if [ "$left" -gt 0 ]; then
        echo $((left - 1)) >"$STUB_FIXTURES/running-fail-left"
        echo "An error occurred (WaiterFailed) when calling the WaitInstance operation: instance did not reach running." >&2
        exit 255
      fi
    fi
    ;;
  terminate-instances)
    # hold-terminate-instances keeps the call running until the release file exists,
    # so a signal can arrive during it. A call that finishes records its instance id
    # in terminated, after the hold.
    [ -e "$STUB_FIXTURES/hold-terminate-instances" ] && {
      for _ in $(seq 1 100); do
        [ -e "$STUB_FIXTURES/release" ] && break
        sleep 0.1
      done
    }
    echo "$4" >>"$STUB_FIXTURES/terminated"
    echo '{"TerminatingInstances":[]}'
    ;;
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
        printf '%s\n' "$@" >"$STUB_FIXTURES/build-$attr.argv"
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
    # The first key of a run is AUTHKEY; each later one carries its request number.
    keys=$(cat "$STUB_FIXTURES/key-count" 2>/dev/null || echo 0)
    keys=$((keys + 1))
    echo "$keys" >"$STUB_FIXTURES/key-count"
    key=tskey-auth-STUB-AUTHKEY-9e2b
    [ "$keys" -eq 1 ] || key=$key-$keys
    echo "{\"key\":\"$key\"}"
    ;;
  *)
    echo "stub curl: unexpected URL" >&2
    exit 6
    ;;
esac
CURLSTUB

# ssh fails for the step named by fail-ssh-<step>: probe (the true readiness
# check), nix-env, switch, switch-boot (switch-to-configuration boot), boot-id
# (a read of the boot id), reboot (the reboot request) or failed-units (the
# failed-unit query). A hold-ssh-<step> fixture keeps the step running until the
# release file exists, so a signal can arrive during it. The boot-id read answers
# boot-id-before until the reboot request has run, and boot-id-after from then
# on, except that the first boot-id-lag reads after the reboot request answer
# boot-id-before. A switch-status fixture makes the in-place switch exit with its
# status, and a failed-units fixture is the output of the failed-unit query.
write_stub ssh <<'SSHSTUB'
case "$*" in
  *nix-env*) step=nix-env ;;
  *'switch-to-configuration boot'*) step=switch-boot ;;
  *switch-to-configuration*) step=switch ;;
  *'systemctl reboot'*) step=reboot ;;
  *'systemctl list-units'*) step=failed-units ;;
  *boot_id*) step=boot-id ;;
  *) step=probe ;;
esac
[ -e "$STUB_FIXTURES/hold-ssh-$step" ] && {
  for _ in $(seq 1 100); do
    [ -e "$STUB_FIXTURES/release" ] && break
    sleep 0.1
  done
}
[ "$step" = reboot ] && : >"$STUB_FIXTURES/rebooted"
[ -e "$STUB_FIXTURES/fail-ssh-$step" ] && {
  echo "ssh: injected failure ($step)" >&2
  exit 255
}
[ "$step" = failed-units ] && {
  cat "$STUB_FIXTURES/failed-units" 2>/dev/null
  exit 0
}
[ "$step" = switch ] && [ -e "$STUB_FIXTURES/switch-status" ] && exit "$(cat "$STUB_FIXTURES/switch-status")"
[ "$step" = boot-id ] && {
  if [ -e "$STUB_FIXTURES/rebooted" ]; then
    lag=$(cat "$STUB_FIXTURES/boot-id-lag" 2>/dev/null || echo 0)
    if [ "$lag" -gt 0 ]; then
      echo $((lag - 1)) >"$STUB_FIXTURES/boot-id-lag"
      cat "$STUB_FIXTURES/boot-id-before"
    else
      cat "$STUB_FIXTURES/boot-id-after"
    fi
  else
    cat "$STUB_FIXTURES/boot-id-before"
  fi
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
{"commonframe-gate":{"instanceType":"c8a.4xlarge","diskGb":80,"spot":true,"idleMinutes":60,"maxHours":24},"muniment-runner":{"instanceType":"m8a.2xlarge","diskGb":200,"spot":false,"idleMinutes":30,"maxHours":12,"cache":true},"reboot-probe":{"instanceType":"c8a.large","diskGb":40,"spot":false,"idleMinutes":30,"maxHours":12,"reboot":true}}
FIXTURE

# The boot ids a box reports before and after its reboot.
BOOT_BEFORE="0b5e1c2a-7d3f-4e8a-9c61-2f4a8d7e1b03"
BOOT_AFTER="e9a4f607-1c2b-4d5e-8f70-3a6b9c8d2e14"
printf '%s\n' "$BOOT_BEFORE" >"$STUB_FIXTURES/boot-id-before"
printf '%s\n' "$BOOT_AFTER" >"$STUB_FIXTURES/boot-id-after"

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
cat >"$STUB_FIXTURES/pricing-g4dn.xlarge.json" <<'FIXTURE'
{"PriceList":["{\"terms\":{\"OnDemand\":{\"X\":{\"priceDimensions\":{\"Y\":{\"pricePerUnit\":{\"USD\":\"0.5260000000\"}}}}}}}"]}
FIXTURE
cat >"$STUB_FIXTURES/pricing-m8a.2xlarge.json" <<'FIXTURE'
{"PriceList":["{\"terms\":{\"OnDemand\":{\"X\":{\"priceDimensions\":{\"Y\":{\"pricePerUnit\":{\"USD\":\"0.4120000000\"}}}}}}}"]}
FIXTURE
cat >"$STUB_FIXTURES/spot-c8a.4xlarge.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T09:00:00+00:00","SpotPrice":"0.2100","AvailabilityZone":"us-west-2a"},{"Timestamp":"2026-10-27T08:00:00+00:00","SpotPrice":"0.1900","AvailabilityZone":"us-west-2a"}]}
FIXTURE
cat >"$STUB_FIXTURES/spot-m8a.large.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T07:00:00+00:00","SpotPrice":"0.0450","AvailabilityZone":"us-west-2b"}]}
FIXTURE

# Zones offering each spot type. c8a.4xlarge lists its zones unsorted, so the
# launcher must sort them.
cat >"$STUB_FIXTURES/offerings-c8a.4xlarge.json" <<'FIXTURE'
{"InstanceTypeOfferings":[
{"InstanceType":"c8a.4xlarge","Location":"us-west-2c","LocationType":"availability-zone"},
{"InstanceType":"c8a.4xlarge","Location":"us-west-2a","LocationType":"availability-zone"},
{"InstanceType":"c8a.4xlarge","Location":"us-west-2b","LocationType":"availability-zone"}
]}
FIXTURE
cat >"$STUB_FIXTURES/offerings-c8a.large.json" <<'FIXTURE'
{"InstanceTypeOfferings":[
{"InstanceType":"c8a.large","Location":"us-west-2b","LocationType":"availability-zone"},
{"InstanceType":"c8a.large","Location":"us-west-2a","LocationType":"availability-zone"}
]}
FIXTURE
cat >"$STUB_FIXTURES/offerings-m8a.2xlarge.json" <<'FIXTURE'
{"InstanceTypeOfferings":[
{"InstanceType":"m8a.2xlarge","Location":"us-west-2c","LocationType":"availability-zone"},
{"InstanceType":"m8a.2xlarge","Location":"us-west-2a","LocationType":"availability-zone"},
{"InstanceType":"m8a.2xlarge","Location":"us-west-2b","LocationType":"availability-zone"}
]}
FIXTURE
cat >"$STUB_FIXTURES/offerings-m8a.large.json" <<'FIXTURE'
{"InstanceTypeOfferings":[
{"InstanceType":"m8a.large","Location":"us-west-2b","LocationType":"availability-zone"},
{"InstanceType":"m8a.large","Location":"us-west-2a","LocationType":"availability-zone"}
]}
FIXTURE
# g4dn.xlarge is offered in both fleet regions, g6.xlarge in Oregon only, and
# p5.48xlarge in neither.
cat >"$STUB_FIXTURES/offerings-g4dn.xlarge.json" <<'FIXTURE'
{"InstanceTypeOfferings":[
{"InstanceType":"g4dn.xlarge","Location":"us-west-2b","LocationType":"availability-zone"},
{"InstanceType":"g4dn.xlarge","Location":"us-west-2a","LocationType":"availability-zone"},
{"InstanceType":"g4dn.xlarge","Location":"us-west-2c","LocationType":"availability-zone"}
]}
FIXTURE
cat >"$STUB_FIXTURES/offerings-g6.xlarge.json" <<'FIXTURE'
{"InstanceTypeOfferings":[
{"InstanceType":"g6.xlarge","Location":"us-west-2b","LocationType":"availability-zone"},
{"InstanceType":"g6.xlarge","Location":"us-west-2a","LocationType":"availability-zone"}
]}
FIXTURE
echo '{"InstanceTypeOfferings":[]}' >"$STUB_FIXTURES/offerings-p5.48xlarge.json"

# eu-west-1 offers none of the classes' and ad-hoc types above, so every existing
# case keeps its call list; it offers g4dn.xlarge in three zones, unsorted.
for itype in c8a.4xlarge c8a.large m8a.2xlarge m8a.large g6.xlarge p5.48xlarge; do
  echo '{"InstanceTypeOfferings":[]}' >"$STUB_FIXTURES/eu-west-1/offerings-$itype.json"
done
cat >"$STUB_FIXTURES/eu-west-1/offerings-g4dn.xlarge.json" <<'FIXTURE'
{"InstanceTypeOfferings":[
{"InstanceType":"g4dn.xlarge","Location":"eu-west-1c","LocationType":"availability-zone"},
{"InstanceType":"g4dn.xlarge","Location":"eu-west-1a","LocationType":"availability-zone"},
{"InstanceType":"g4dn.xlarge","Location":"eu-west-1b","LocationType":"availability-zone"}
]}
FIXTURE
t_irl=$(date -u -d '70 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
cat >"$STUB_FIXTURES/eu-west-1/instances.json" <<FIXTURE
{"Reservations":[{"Instances":[
  {"InstanceId":"i-0ireland0000001","InstanceType":"m8a.large","State":{"Name":"running"},"LaunchTime":"$t_irl","Placement":{"AvailabilityZone":"eu-west-1b"},"Tags":[{"Key":"Name","Value":"ec2-irl7k"},{"Key":"fleet","Value":"ec2"},{"Key":"fleet-class","Value":"adhoc"}]}
]}]}
FIXTURE
# Ireland prices m8a.large differently from Oregon, so a row priced in the wrong
# region shows.
cat >"$STUB_FIXTURES/eu-west-1/pricing-m8a.large.json" <<'FIXTURE'
{"PriceList":["{\"terms\":{\"OnDemand\":{\"X\":{\"priceDimensions\":{\"Y\":{\"pricePerUnit\":{\"USD\":\"0.1300000000\"}}}}}}}"]}
FIXTURE
# Ireland's g4dn.xlarge on-demand price is dearer than Oregon's by default.
cat >"$STUB_FIXTURES/eu-west-1/pricing-g4dn.xlarge.json" <<'FIXTURE'
{"PriceList":["{\"terms\":{\"OnDemand\":{\"X\":{\"priceDimensions\":{\"Y\":{\"pricePerUnit\":{\"USD\":\"0.6120000000\"}}}}}}}"]}
FIXTURE
cat >"$STUB_FIXTURES/eu-west-1/spot-m8a.large.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T07:00:00+00:00","SpotPrice":"0.0510","AvailabilityZone":"eu-west-1b"}]}
FIXTURE
# g4dn.xlarge's spot placement scores tie and Oregon's spot price is lower, so the
# default spot walk keeps the fixed order. The score answer is read in us-west-2.
cat >"$STUB_FIXTURES/scores-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPlacementScores":[{"Region":"us-west-2","Score":5},{"Region":"eu-west-1","Score":5}]}
FIXTURE
cat >"$STUB_FIXTURES/spot-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T07:00:00+00:00","SpotPrice":"0.2100","AvailabilityZone":"us-west-2a"}]}
FIXTURE
cat >"$STUB_FIXTURES/eu-west-1/spot-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T07:00:00+00:00","SpotPrice":"0.2400","AvailabilityZone":"eu-west-1a"}]}
FIXTURE
cat >"$STUB_FIXTURES/eu-west-1/security-groups.json" <<'FIXTURE'
{"SecurityGroups":[{"GroupId":"sg-0ireland0000001","GroupName":"ec2-fleet"}]}
FIXTURE

# Base AMI lists. images.json is what describe-images returns before a rebuild;
# images-after-register.json is what it returns once the stub register-image has
# run, and use_images sets both from the named fixtures.
cat >"$STUB_FIXTURES/images-full.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-older00000001","State":"available","CreationDate":"2026-09-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-previous"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000001"}}]},
{"ImageId":"ami-newest00000002","State":"available","CreationDate":"2026-10-20T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000002"}}]}
]}
FIXTURE
echo '{"Images":[]}' >"$STUB_FIXTURES/images-none.json"
# The oldest AMI already carries the base toplevel, so a match on any AMI but
# the newest must not count.
cat >"$STUB_FIXTURES/images-stale.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-oldest000000001","State":"available","CreationDate":"2026-08-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000011"}}]},
{"ImageId":"ami-middle00000002","State":"available","CreationDate":"2026-09-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-middle"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000012"}}]},
{"ImageId":"ami-latest00000003","State":"available","CreationDate":"2026-10-20T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-latest"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000013"}}]}
]}
FIXTURE
cat >"$STUB_FIXTURES/images-registered.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-oldest000000001","State":"available","CreationDate":"2026-08-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000011"}}]},
{"ImageId":"ami-middle00000002","State":"available","CreationDate":"2026-09-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-middle"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000012"}}]},
{"ImageId":"ami-latest00000003","State":"available","CreationDate":"2026-10-20T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-latest"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000013"}}]},
{"ImageId":"ami-registered0000004","State":"available","CreationDate":"2026-10-27T09:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0feed00000000001"}}]}
]}
FIXTURE
cat >"$STUB_FIXTURES/images-registered-only.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-registered0000004","State":"available","CreationDate":"2026-10-27T09:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0feed00000000001"}}]}
]}
FIXTURE
# The newest AMI matches the base toplevel but is still pending, and the newest
# available AMI carries another toplevel: the pending one must not be used.
cat >"$STUB_FIXTURES/images-pending-newest.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-available00000006","CreationDate":"2026-09-01T10:00:00.000Z","State":"available","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-previous"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000016"}}]},
{"ImageId":"ami-pending000000005","CreationDate":"2026-10-20T10:00:00.000Z","State":"pending","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000015"}}]}
]}
FIXTURE
# The newest AMI matches the base toplevel and is still pending, and an older
# available AMI matches it too: the older available AMI is the one to use.
cat >"$STUB_FIXTURES/images-pending-match.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-available00000006","CreationDate":"2026-09-01T10:00:00.000Z","State":"available","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000016"}}]},
{"ImageId":"ami-pending000000005","CreationDate":"2026-10-20T10:00:00.000Z","State":"pending","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0a1d00000000015"}}]}
]}
FIXTURE
# Ireland's base AMI lists. The newest one carries the base toplevel, so the
# default needs no rebuild; images-stale has a mismatched newest AMI.
cat >"$STUB_FIXTURES/eu-west-1/images-full.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-irelandold0001","State":"available","CreationDate":"2026-09-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-previous"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0e1d00000000001"}}]},
{"ImageId":"ami-irelandnew0002","State":"available","CreationDate":"2026-10-20T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0e1d00000000002"}}]}
]}
FIXTURE
cat >"$STUB_FIXTURES/eu-west-1/images-stale.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-irestale-old1","State":"available","CreationDate":"2026-08-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0e1d00000000011"}}]},
{"ImageId":"ami-irestale-mid2","State":"available","CreationDate":"2026-09-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-middle"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0e1d00000000012"}}]},
{"ImageId":"ami-irestale-new3","State":"available","CreationDate":"2026-10-20T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-latest"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0e1d00000000013"}}]}
]}
FIXTURE
cat >"$STUB_FIXTURES/eu-west-1/images-registered.json" <<'FIXTURE'
{"Images":[
{"ImageId":"ami-irestale-old1","State":"available","CreationDate":"2026-08-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0e1d00000000011"}}]},
{"ImageId":"ami-irestale-mid2","State":"available","CreationDate":"2026-09-01T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-middle"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0e1d00000000012"}}]},
{"ImageId":"ami-irestale-new3","State":"available","CreationDate":"2026-10-20T10:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-latest"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0e1d00000000013"}}]},
{"ImageId":"ami-irelandnew0005","State":"available","CreationDate":"2026-10-27T09:00:00.000Z","Tags":[{"Key":"fleet","Value":"ec2-base"},{"Key":"fleet-toplevel","Value":"fixture-toplevel-base"}],"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0feed00000000001"}}]}
]}
FIXTURE
cp "$STUB_FIXTURES/eu-west-1/images-full.json" "$STUB_FIXTURES/eu-west-1/images.json"
cp "$STUB_FIXTURES/eu-west-1/images-registered.json" "$STUB_FIXTURES/eu-west-1/images-after-register.json"

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

# launch_signalled <signal> <step> <log pattern> <ec2 args...>: starts the launcher
# with job control on, so SIGINT is not ignored on entry, holds the stub step
# <step> (its hold-<step> fixture), waits until the stub log has a line matching
# <log pattern>, sends the signal to the launcher while the step runs, then
# releases the step. With signal_group=yes the signal also goes to the launcher's
# process group. Sets STATUS.
launch_signalled() {
  local sig=$1 step=$2 pat=$3 pid i
  shift 3
  : >"$STUB_FIXTURES/hold-$step"
  set -m
  "$EC2" "$@" >"$OUT" 2>"$ERR" &
  pid=$!
  set +m
  for i in $(seq 1 100); do
    grep -q "$pat" "$STUB_LOG" && break
    sleep 0.1
  done
  grep -q "$pat" "$STUB_LOG" || fail "no $step call ran before SIG$sig"
  kill -s "$sig" "$pid" 2>/dev/null
  if [ "$signal_group" = yes ]; then
    kill -s "$sig" -- "-$pid" 2>/dev/null
  fi
  : >"$STUB_FIXTURES/release"
  if wait "$pid"; then
    STATUS=0
  else
    STATUS=$?
  fi
  rm -f "$STUB_FIXTURES/hold-$step" "$STUB_FIXTURES/release"
}

# run <ec2 args...>: runs the launcher, sets STATUS/OUT/ERR, resets the call log.
# With probe_signal set, the launcher gets that signal during its ssh probe.
run() {
  : >"$STUB_LOG"
  : >"$STUB_REGION_LOG"
  rm -f "$STUB_FIXTURES/user-data.seen" "$STUB_FIXTURES/user-data.mode" "$STUB_FIXTURES/nix-sshopts.seen" \
    "$STUB_FIXTURES/registered" "$STUB_FIXTURES/eu-west-1/registered" "$STUB_FIXTURES/rebooted"
  rm -f "$STUB_FIXTURES"/user-data.*.seen "$STUB_FIXTURES/key-count" "$STUB_FIXTURES/terminated"
  if [ -n "$probe_signal" ]; then
    launch_signalled "$probe_signal" ssh-probe '^ssh ' "$@"
  elif [ -n "$run_signal" ]; then
    launch_signalled "$run_signal" run-instances '^aws ec2 run-instances ' "$@"
  elif [ -n "$terminate_signal" ]; then
    launch_signalled "$terminate_signal" terminate-instances '^aws ec2 terminate-instances --instance-ids i-0launched00000001' "$@"
  elif "$EC2" "$@" >"$OUT" 2>"$ERR"; then
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
# expect_region <desc> <region> <literal>...: one ec2 call in the region contains
# every literal. expect_no_region: no ec2 call in the region contains a literal.
expect_region() {
  local desc=$1 region=$2 line lit ok found=no
  shift 2
  while IFS= read -r line; do
    case $line in "$region "*) ;; *) continue ;; esac
    ok=yes
    for lit in "$@"; do
      case $line in *"$lit"*) ;; *) ok=no ;; esac
    done
    if [ "$ok" = yes ]; then
      found=yes
      break
    fi
  done <"$STUB_REGION_LOG"
  [ "$found" = yes ] || fail "$desc: no $region call with: $*"
}
expect_no_region() {
  local desc=$1 region=$2 lit
  shift 2
  for lit in "$@"; do
    if grep -F -- "$region " "$STUB_REGION_LOG" | grep -F -q -- "$lit"; then
      fail "$desc: unexpected $region call containing: $lit"
    fi
  done
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
# expect_terminations <desc> <n>: exactly n terminates for the launched instance.
expect_terminations() {
  local count
  count=$(grep -c -F -- 'terminate-instances --instance-ids i-0launched00000001' "$STUB_LOG")
  [ "$count" -eq "$2" ] || fail "$1: want $2 terminate-instances for i-0launched00000001, got $count"
}
# expect_terminated <desc>: exactly one terminate for the launched instance.
expect_terminated() {
  expect_terminations "$1" 1
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
# expect_attempt_userdata <desc> <call> <name> <key>: the user-data of run-instances
# call number <call> carried the name and key, and had exactly two lines.
expect_attempt_userdata() {
  local seen="$STUB_FIXTURES/user-data.$2.seen"
  if [ ! -f "$seen" ]; then
    fail "$1: run-instances call $2 received no user-data file"
    return
  fi
  grep -x -F -q "EC2_FLEET_NAME=$3" "$seen" || fail "$1: call $2 user-data lacks EC2_FLEET_NAME=$3"
  grep -x -F -q "EC2_FLEET_TS_AUTHKEY=$4" "$seen" || fail "$1: call $2 user-data lacks EC2_FLEET_TS_AUTHKEY=$4"
  [ "$(wc -l <"$seen")" -eq 2 ] || fail "$1: call $2 user-data is not exactly two lines"
}
inject() {
  : >"$STUB_FIXTURES/fail-$1"
}
clear_faults() {
  local dir
  rm -f "$STUB_FIXTURES"/fail-* "$STUB_FIXTURES"/warn-run-instances "$STUB_FIXTURES/running-fail-left"
  rm -f "$STUB_FIXTURES/switch-status" "$STUB_FIXTURES/failed-units"
  for dir in "$STUB_FIXTURES" "$STUB_FIXTURES/eu-west-1"; do
    rm -f "$dir"/no-capacity-* "$dir"/other-error-* "$dir"/throttle-* "$dir"/account-throttle "$dir"/quota-*
    rm -f "$dir"/timeout-* "$dir"/no-id-*
    rm -rf -- "$dir/by-token"
  done
}
# client_token_of <n>: the --client-token of run-instances call number <n>.
client_token_of() {
  grep '^aws ec2 run-instances ' "$STUB_LOG" | sed -n "$1p" | grep -o -- '--client-token [^ ]*' | cut -d' ' -f2
}
# expect_run_count <desc> <n>: run-instances was called exactly n times.
expect_run_count() {
  local count
  count=$(grep -c '^aws ec2 run-instances ' "$STUB_LOG")
  [ "$count" -eq "$2" ] || fail "$1: want $2 run-instances call(s), got $count"
}
# run_placements: one line per run-instances call, in call order: "zone <name>"
# for a placed call, " spot" appended to a spot call, "unplaced" for no placement.
run_placements() {
  grep '^aws ec2 run-instances ' "$STUB_LOG" |
    sed -E -e 's/^.*--user-data file:[^ ]+//' -e 's/ --iam-instance-profile Name=[^ ]+//' \
      -e 's/ --instance-market-options .*$/ spot/' \
      -e 's/^ --placement AvailabilityZone=/zone /' -e 's/^$/unplaced/'
}
# expect_placements <desc> <placement>...: the run-instances calls placed as listed.
expect_placements() {
  local desc=$1 want got
  shift
  want=$(printf '%s\n' "$@")
  got=$(run_placements)
  [ "$got" = "$want" ] || fail "$desc: run-instances placements are [${got//$'\n'/; }], want [${want//$'\n'/; }]"
}
# use_images <before> <after>: the describe-images lists from the named fixtures,
# before a rebuild and after the new AMI is registered.
use_images() {
  cp "$STUB_FIXTURES/$1.json" "$STUB_FIXTURES/images.json" || exit 1
  cp "$STUB_FIXTURES/$2.json" "$STUB_FIXTURES/images-after-register.json" || exit 1
}
# use_eu_images <before> <after>: as use_images, for Ireland's lists.
use_eu_images() {
  cp "$STUB_FIXTURES/eu-west-1/$1.json" "$STUB_FIXTURES/eu-west-1/images.json" || exit 1
  cp "$STUB_FIXTURES/eu-west-1/$2.json" "$STUB_FIXTURES/eu-west-1/images-after-register.json" || exit 1
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
expect_out 'fleet boxes in us-west-2 and eu-west-1$' "help names both fleet regions"
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
expect_out '--spot' "help lists --spot"
expect_out '--spot-only' "help lists --spot-only"
expect_out '--override-input <input> <flake-url>' "help lists --override-input"
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

# ls lists the Ireland box after Oregon's rows, priced and spot-priced in eu-west-1.
expect_out '^ec2-irl7k +adhoc +m8a\.large +no +1h1[0-9]m +0\.1300000000 +0\.0510$' "ls row for the Ireland box priced in eu-west-1"
last_west=$(grep -n '^ec2-x9z ' "$OUT" | cut -d: -f1)
irl=$(grep -n '^ec2-irl7k ' "$OUT" | cut -d: -f1)
if [ -z "$last_west" ] || [ -z "$irl" ] || [ "$irl" -le "$last_west" ]; then
  fail "ls lists the Ireland box after all us-west-2 rows"
fi
expect_region "ls describes instances in eu-west-1" eu-west-1 "ec2 describe-instances"
expect_region "ls describes instances in us-west-2" us-west-2 "ec2 describe-instances"
expect_log 'Field=regionCode,Value=eu-west-1' "ls prices the Ireland box in eu-west-1"
expect_region "ls asks Ireland spot price in eu-west-1 for its zone" eu-west-1 \
  "describe-spot-price-history" "--instance-types m8a.large" "--availability-zone eu-west-1b"
expect_no_region "ls asks no Ireland zone in us-west-2" us-west-2 "--availability-zone eu-west-1b"
expect_region "ls asks Oregon spot price in us-west-2 for its zone" us-west-2 \
  "describe-spot-price-history" "--availability-zone us-west-2b"

# ls exits nonzero when any AWS call it depends on fails.
for failing in ec2-describe-instances pricing-get-products ec2-describe-spot-price-history; do
  : >"$STUB_FIXTURES/fail-$failing"
  run ls
  expect_nonzero "ls with $failing failing"
  rm -f "$STUB_FIXTURES/fail-$failing"
done

# ls exits nonzero when one region's call fails alone.
for failing in eu-west-1-ec2-describe-instances eu-west-1-pricing-get-products eu-west-1-ec2-describe-spot-price-history; do
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

# down: a box in either region is terminated in the region it runs in.
run down ec2-irl7k
expect_status 0 "down of the Ireland box"
expect_region "down terminates the Ireland box in eu-west-1" eu-west-1 "terminate-instances --instance-ids i-0ireland0000001"
expect_no_region "down of the Ireland box terminates nothing in us-west-2" us-west-2 "terminate-instances"
if [ "$(grep -c 'terminate-instances' "$STUB_LOG")" -ne 1 ]; then
  fail "down of the Ireland box made more than one terminate-instances call"
fi

run down commonframe-gate-a1b
expect_status 0 "down of the Oregon box"
expect_region "down terminates the Oregon box in us-west-2" us-west-2 "terminate-instances --instance-ids i-0fixture00000001"
expect_no_region "down of the Oregon box terminates nothing in eu-west-1" eu-west-1 "terminate-instances"

# down: one name held by a box in each region terminates nothing.
cp "$STUB_FIXTURES/eu-west-1/instances.json" "$work/ireland-instances.json"
cat >"$STUB_FIXTURES/eu-west-1/instances.json" <<FIXTURE
{"Reservations":[{"Instances":[
  {"InstanceId":"i-0ireland0000002","InstanceType":"c8a.large","State":{"Name":"running"},"LaunchTime":"$t_irl","Placement":{"AvailabilityZone":"eu-west-1a"},"Tags":[{"Key":"Name","Value":"commonframe-gate-a1b"},{"Key":"fleet","Value":"ec2"},{"Key":"fleet-class","Value":"commonframe-gate"}]}
]}]}
FIXTURE
run down commonframe-gate-a1b
expect_nonzero "down of a name held in both regions"
expect_err 'more than one fleet box named commonframe-gate-a1b' "down of a name held in both regions names the ambiguity"
expect_no_log 'terminate-instances' "down of a name held in both regions terminates nothing"
cp "$work/ireland-instances.json" "$STUB_FIXTURES/eu-west-1/instances.json"

# down: a failed lookup in either region terminates nothing and exits nonzero.
inject eu-west-1-ec2-describe-instances
run down commonframe-gate-a1b
expect_nonzero "down with eu-west-1 describe-instances failing"
expect_no_log 'terminate-instances' "down with eu-west-1 describe-instances failing terminates nothing"
clear_faults
inject us-west-2-ec2-describe-instances
run down ec2-irl7k
expect_nonzero "down with us-west-2 describe-instances failing"
expect_no_log 'terminate-instances' "down with us-west-2 describe-instances failing terminates nothing"
clear_faults

# up: bad arguments are refused before any AWS, Tailscale, ssh or nix build call.
export EC2_FLEET_AWS_ENV_FILE=$ENV_FILE
export EC2_FLEET_TS_ENV_FILE=$TS_ENV_FILE
unset EC2_FLEET_READY_TIMEOUT
for args in "" "--type c8a.large" "--type c8a.large --disk 0" "--type c8a.large --disk 20x" \
  "commonframe-gate --spot" "commonframe-gate extra" "--type c8a.large --disk 20 commonframe-gate" \
  "commonframe-gate --override-input halmasuit" "commonframe-gate --override-input" \
  "--type c8a.large --disk 20 --override-input halmasuit git+file:///fixture/halmasuit"; do
  run up $args
  expect_nonzero "up $args"
  expect_no_log '^(aws|curl|ssh) |nix build' "up $args calls no AWS, Tailscale, ssh or nix build"
done

run up commonframe-gate --override-input halmasuit ""
expect_nonzero "up with an empty override URL"
expect_no_log '^(aws|curl|ssh) |nix build' "up with an empty override URL calls no AWS, Tailscale, ssh or nix build"

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

# A newest base AMI that is still pending is never launched. Here the newest
# available AMI carries another toplevel, so the image is rebuilt instead.
use_images images-pending-newest images-registered-only
rebuild_run up commonframe-gate
expect_status 0 "up with a pending newest base AMI"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up with a pending newest base AMI prints the ready line"
expect_rebuilt "up with a pending newest base AMI" fixture-toplevel-base
expect_no_fixed "--image-id ami-pending000000005" "up with a pending newest base AMI never launches it"

# A newest base AMI that is still pending does not hide an older available AMI
# that matches the toplevel: that older AMI is launched and nothing is rebuilt.
use_images images-pending-match images-registered-only
run up commonframe-gate
expect_status 0 "up with a pending newest base AMI and an older matching one"
expect_fixed "--image-id ami-available00000006" "up launches the older available base AMI"
expect_no_fixed "--image-id ami-pending000000005" "up with a pending newest base AMI and an older matching one never launches the pending AMI"

# A failure in the image build, upload, register or AMI wait stops before
# Tailscale and run-instances, and exits nonzero. A failure in the prune also
# stops the launch. A register failure deletes the snapshot it uploaded, since
# no AMI uses it. A failed AMI wait deregisters the AMI it registered and then
# deletes its snapshot.
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
    ec2-wait)
      expect_order "up with the image wait failing deregisters the new AMI, then deletes its snapshot" \
        "aws ec2 wait image-available --image-ids ami-registered0000004" \
        "aws ec2 deregister-image --image-id ami-registered0000004" \
        "aws ec2 delete-snapshot --snapshot-id snap-0feed00000000001"
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

inject ec2-describe-instance-type-offerings
run up commonframe-gate
expect_nonzero "up with the zone listing failing"
expect_no_fixed 'run-instances' "up with the zone listing failing launches nothing"
expect_no_fixed 'api/v2' "up with the zone listing failing asks Tailscale nothing"
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
expect_fixed "aws ec2 describe-instance-type-offerings --output json --location-type availability-zone" "up lists the zones offering the type"
expect_fixed "--placement AvailabilityZone=us-west-2a" "up places the spot request in the first sorted zone"
expect_out '^market spot us-west-2a$' "up prints the spot market line"
[ "$(tail -n 1 "$OUT")" = "$name ready" ] || fail "up commonframe-gate: the ready line is not the last stdout line"
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
  "nix copy --no-check-sigs --substitute-on-destination --to ssh-ng://joshsymonds@$name $TL" \
  "joshsymonds@$name sudo nix-env -p /nix/var/nix/profiles/system --set $TL" \
  "joshsymonds@$name sudo $TL/bin/switch-to-configuration switch"
expect_no_fixed "switch-to-configuration boot" "up commonframe-gate boots nothing"
expect_no_fixed "systemctl reboot" "up commonframe-gate reboots nothing"
expect_fixed "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$XDG_STATE_HOME/ec2-fleet/known_hosts" "up sets the ssh host-key options"
[ -d "$XDG_STATE_HOME/ec2-fleet" ] || fail "up did not create the ec2-fleet state directory"
grep -F -q "UserKnownHostsFile=$XDG_STATE_HOME/ec2-fleet/known_hosts" "$STUB_FIXTURES/nix-sshopts.seen" || fail "up did not pass the host-key options to nix copy"
# Every launcher ssh call and the nix copy disable mux, so the launcher never
# leaves a ControlMaster connected to a box.
grep -F -q -- "-o ControlMaster=no" "$STUB_FIXTURES/nix-sshopts.seen" || fail "up did not pass ControlMaster=no to nix copy"
grep -F -q -- "-o ControlPath=none" "$STUB_FIXTURES/nix-sshopts.seen" || fail "up did not pass ControlPath=none to nix copy"
mux_calls=$(grep -E '^ssh ' "$STUB_LOG" | grep -F -- "joshsymonds@$name")
[ "$(printf '%s\n' "$mux_calls" | grep -c .)" -eq 3 ] || fail "up made an unexpected number of ssh calls to $name"
while IFS= read -r call; do
  case $call in *"-o ControlMaster=no"*) ;; *) fail "ssh call without ControlMaster=no: $call" ;; esac
  case $call in *"-o ControlPath=none"*) ;; *) fail "ssh call without ControlPath=none: $call" ;; esac
done <<<"$mux_calls"
expect_no_fixed "terminate-instances" "up commonframe-gate terminates nothing on success"

# up commonframe-gate with overrides: each pair reaches the class toplevel build
# as separate argv words, in order and verbatim. The ec2Classes eval and the base
# build carry no override.
URL_A='git+file:///fixture/halmasuit?rev=0123456789abcdef0123456789abcdef01234567&dir=nix'
URL_B='github:NixOS/nixpkgs/nixos-unstable'
rm -f "$STUB_FIXTURES"/build-*.argv
run up commonframe-gate --override-input halmasuit "$URL_A" --override-input nixpkgs "$URL_B"
expect_status 0 "up commonframe-gate with two overrides"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up commonframe-gate with two overrides prints the ready line"
expect_no_log '^nix eval .*--override-input' "up with overrides evaluates ec2Classes without overrides"
expected_class=$(printf '%s\n' build --no-link --print-out-paths --override-input halmasuit "$URL_A" \
  --override-input nixpkgs "$URL_B" /fixture/flake#nixosConfigurations.ec2-commonframe-gate.config.system.build.toplevel)
[ "$(cat "$STUB_FIXTURES/build-commonframe-gate.argv")" = "$expected_class" ] ||
  fail "up with overrides: class toplevel build argv is not the expected overrides in order"
expected_base=$(printf '%s\n' build --no-link --print-out-paths /fixture/flake#nixosConfigurations.ec2-base.config.system.build.toplevel)
[ "$(cat "$STUB_FIXTURES/build-base.argv")" = "$expected_base" ] ||
  fail "up with overrides: base toplevel build argv carries an override"

# A class launched with an empty override set builds the class toplevel with no
# override words at all.
rm -f "$STUB_FIXTURES"/build-*.argv
run up commonframe-gate
expect_status 0 "up commonframe-gate without overrides"
expected_plain=$(printf '%s\n' build --no-link --print-out-paths /fixture/flake#nixosConfigurations.ec2-commonframe-gate.config.system.build.toplevel)
[ "$(cat "$STUB_FIXTURES/build-commonframe-gate.argv")" = "$expected_plain" ] ||
  fail "up without overrides: class toplevel build argv gained words"

# A spot class tries each zone that offers its type in sorted order, moving on
# only past InsufficientInstanceCapacity. It stops at the first launch.
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
run up commonframe-gate
expect_status 0 "up commonframe-gate with us-west-2a out of capacity"
expect_out '^market spot us-west-2b$' "up with us-west-2a out of capacity prints the market line of us-west-2b"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up with us-west-2a out of capacity prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_order "up with us-west-2a out of capacity tries us-west-2a, then us-west-2b" \
  "--placement AvailabilityZone=us-west-2a" \
  "--placement AvailabilityZone=us-west-2b"
expect_no_fixed "--placement AvailabilityZone=us-west-2c" "up with us-west-2a out of capacity does not try us-west-2c"
expect_run_count "up with us-west-2a out of capacity" 2
expect_userdata "up with us-west-2a out of capacity" "$name"
expect_no_fixed "terminate-instances" "up with us-west-2a out of capacity terminates nothing on success"
clear_faults

# Every zone out of capacity: the spot zones in sorted order, then the on-demand
# zones in sorted order, then one on-demand launch with no placement and no
# market options.
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/no-capacity-us-west-2b"
: >"$STUB_FIXTURES/no-capacity-us-west-2c"
run up commonframe-gate
expect_status 0 "up commonframe-gate with every zone out of capacity"
expect_out '^market on-demand$' "up with every zone out of capacity prints the on-demand market line"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up with every zone out of capacity prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_placements "up with every zone out of capacity" \
  "zone us-west-2a spot" "zone us-west-2b spot" "zone us-west-2c spot" \
  "zone us-west-2a" "zone us-west-2b" "zone us-west-2c" "unplaced"
expect_run_count "up with every zone out of capacity" 7
expect_err 'no on-demand capacity for c8a\.4xlarge in us-west-2c$' "up with every zone out of capacity names the on-demand zone skipped"
expect_userdata "up with every zone out of capacity" "$name"
expect_no_fixed "terminate-instances" "up with every zone out of capacity terminates nothing on success"
clear_faults

# up --spot-only: every spot zone out of capacity fails the launch with no
# on-demand attempt, and the failure names spot. The spot zones run in sorted order.
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/no-capacity-us-west-2b"
: >"$STUB_FIXTURES/no-capacity-us-west-2c"
run up commonframe-gate --spot-only
expect_nonzero "up commonframe-gate --spot-only with every spot zone out of capacity"
expect_placements "up commonframe-gate --spot-only with every spot zone out of capacity" \
  "zone us-west-2a spot" "zone us-west-2b spot" "zone us-west-2c spot"
expect_run_count "up commonframe-gate --spot-only with every spot zone out of capacity" 3
expect_err 'no region could launch c8a\.4xlarge as spot; nothing was launched' "up commonframe-gate --spot-only with every spot zone out of capacity names spot"
expect_no_out '^market ' "up commonframe-gate --spot-only with every spot zone out of capacity prints no market line"
clear_faults

# up --spot-only placing on the first try: the spot market line and the ready line.
run up commonframe-gate --spot-only
expect_status 0 "up commonframe-gate --spot-only placing first try"
expect_out '^market spot us-west-2a$' "up commonframe-gate --spot-only placing first try prints the spot market line"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up commonframe-gate --spot-only placing first try prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
[ "$(tail -n 1 "$OUT")" = "$name ready" ] || fail "up commonframe-gate --spot-only placing first try does not end with the ready line"
expect_placements "up commonframe-gate --spot-only placing first try" "zone us-west-2a spot"
expect_run_count "up commonframe-gate --spot-only placing first try" 1
expect_userdata "up commonframe-gate --spot-only placing first try" "$name"
expect_no_fixed "terminate-instances" "up commonframe-gate --spot-only placing first try terminates nothing"
clear_faults

# up --spot-only on a spot-false class is refused before any AWS, Tailscale, ssh or
# nix build call.
run up muniment-runner --spot-only
expect_nonzero "up muniment-runner --spot-only"
expect_err 'not a spot class' "up muniment-runner --spot-only names the refusal"
expect_no_log '^(aws|curl|ssh) |nix build' "up muniment-runner --spot-only calls no AWS, Tailscale, ssh or nix build"

# Ad-hoc --spot-only implies --spot: every spot zone out of capacity fails the launch
# with no on-demand attempt, and the failure names spot.
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/no-capacity-us-west-2b"
run up --type c8a.large --disk 40 --spot-only
expect_nonzero "ad-hoc up --spot-only with every spot zone out of capacity"
expect_placements "ad-hoc up --spot-only with every spot zone out of capacity" \
  "zone us-west-2a spot" "zone us-west-2b spot"
expect_run_count "ad-hoc up --spot-only with every spot zone out of capacity" 2
expect_err 'no region could launch c8a\.large as spot; nothing was launched' "ad-hoc up --spot-only with every spot zone out of capacity names spot"
expect_no_out '^market on-demand$' "ad-hoc up --spot-only with every spot zone out of capacity prints no on-demand market line"
clear_faults

# Ad-hoc --spot-only placing on the first try requests spot.
run up --type c8a.large --disk 40 --spot-only
expect_status 0 "ad-hoc up --spot-only placing first try"
expect_out '^market spot us-west-2a$' "ad-hoc up --spot-only placing first try prints the spot market line"
expect_placements "ad-hoc up --spot-only placing first try" "zone us-west-2a spot"
clear_faults

# A non-capacity error in a zone stops the launch: no further zone, no
# on-demand launch, nothing launched, nothing terminated.
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/other-error-us-west-2b"
run up commonframe-gate
expect_nonzero "up commonframe-gate with a non-capacity error in us-west-2b"
expect_err 'UnsupportedOperation' "up with a non-capacity error prints the error"
expect_run_count "up with a non-capacity error in us-west-2b" 2
expect_no_fixed "--placement AvailabilityZone=us-west-2c" "up with a non-capacity error in us-west-2b does not try us-west-2c"
expect_no_out '^market ' "up with a non-capacity error prints no market line"
expect_no_fixed "wait instance-running" "up with a non-capacity error waits for no instance"
expect_no_fixed "terminate-instances" "up with a non-capacity error terminates nothing"
clear_faults

# A zone-scoped throttle on a spot launch skips that zone, like a capacity
# error: the launcher names the zone and the throttle, then launches in the next
# zone. The ready line stays last.
: >"$STUB_FIXTURES/throttle-spot-us-west-2a"
run up commonframe-gate
expect_status 0 "up commonframe-gate with us-west-2a throttled"
expect_out '^market spot us-west-2b$' "up with us-west-2a throttled prints the market line of us-west-2b"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up with us-west-2a throttled prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
[ "$(tail -n 1 "$OUT")" = "$name ready" ] || fail "up with us-west-2a throttled: the ready line is not last"
expect_err 'spot launch throttled in us-west-2a$' "up with us-west-2a throttled names the zone and the throttle"
expect_placements "up with us-west-2a throttled" "zone us-west-2a spot" "zone us-west-2b spot"
expect_run_count "up with us-west-2a throttled" 2
expect_userdata "up with us-west-2a throttled" "$name"
expect_no_fixed "terminate-instances" "up with us-west-2a throttled terminates nothing on success"
clear_faults

# Spot throttled in every zone, and on-demand throttled in us-west-2a only: the
# on-demand walk skips us-west-2a and launches in us-west-2b with no market
# options.
: >"$STUB_FIXTURES/throttle-spot-us-west-2a"
: >"$STUB_FIXTURES/throttle-spot-us-west-2b"
: >"$STUB_FIXTURES/throttle-spot-us-west-2c"
: >"$STUB_FIXTURES/throttle-on-demand-us-west-2a"
run up commonframe-gate
expect_status 0 "up commonframe-gate with every spot zone throttled and on-demand us-west-2a throttled"
expect_out '^market on-demand$' "up with every spot zone throttled prints the on-demand market line"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up with every spot zone throttled prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
[ "$(tail -n 1 "$OUT")" = "$name ready" ] || fail "up with every spot zone throttled: the ready line is not last"
expect_placements "up with every spot zone throttled" \
  "zone us-west-2a spot" "zone us-west-2b spot" "zone us-west-2c spot" \
  "zone us-west-2a" "zone us-west-2b"
expect_run_count "up with every spot zone throttled" 5
expect_err 'on-demand launch throttled in us-west-2a$' "up with on-demand us-west-2a throttled names the zone and the throttle"
expect_userdata "up with every spot zone throttled" "$name"
expect_no_fixed "terminate-instances" "up with every spot zone throttled terminates nothing on success"
clear_faults

# An account-level throttle names no zone: it is not zone-scoped, so the launch
# stops at the first attempt with the error, launching nothing.
: >"$STUB_FIXTURES/account-throttle"
run up commonframe-gate
expect_nonzero "up commonframe-gate with an account-level throttle"
expect_err 'RequestLimitExceeded' "up with an account-level throttle prints the error"
expect_run_count "up with an account-level throttle" 1
expect_no_out '^market ' "up with an account-level throttle prints no market line"
expect_no_fixed "wait instance-running" "up with an account-level throttle waits for no instance"
expect_no_fixed "terminate-instances" "up with an account-level throttle terminates nothing"
clear_faults

# A run-instances call that times out after starting a box: the launcher looks the
# box up by the attempt's client token in its region, terminates it, and exits
# nonzero.
: >"$STUB_FIXTURES/timeout-us-west-2a"
run up commonframe-gate
tok=$(client_token_of 1)
[ -n "$tok" ] || fail "up with run-instances timing out after a box started: run-instances carried no --client-token"
expect_nonzero "up commonframe-gate with run-instances timing out after a box started"
expect_err 'RequestTimeout' "up with run-instances timing out after a box started prints the error"
expect_run_count "up with run-instances timing out after a box started" 1
expect_region "up with run-instances timing out after a box started looks up its token in us-west-2" us-west-2 \
  "describe-instances" "Name=client-token,Values=$tok"
expect_region "up with run-instances timing out after a box started terminates the box in us-west-2" us-west-2 \
  "terminate-instances --instance-ids i-0launched00000001"
expect_terminated "up with run-instances timing out after a box started"
clear_faults

# run-instances answers with no id after starting a box: the launch is a failure
# with no launched instance, so the lookup by token finds and terminates the box.
: >"$STUB_FIXTURES/no-id-us-west-2a"
run up commonframe-gate
tok=$(client_token_of 1)
[ -n "$tok" ] || fail "up with run-instances returning no id: run-instances carried no --client-token"
expect_nonzero "up commonframe-gate with run-instances returning no id"
expect_err 'run-instances returned no instance id' "up with run-instances returning no id names the missing id"
expect_run_count "up with run-instances returning no id" 1
expect_region "up with run-instances returning no id looks up its token in us-west-2" us-west-2 \
  "describe-instances" "Name=client-token,Values=$tok"
expect_terminated "up with run-instances returning no id"
clear_faults

# An unrecognised run-instances error that started nothing: the lookup makes its six
# tries in us-west-2, finds no box, terminates nothing, and names the token and the
# region on stderr. The message no longer says nothing was launched.
: >"$STUB_FIXTURES/other-error-us-west-2a"
run up commonframe-gate
tok=$(client_token_of 1)
[ -n "$tok" ] || fail "up with an unrecognised run-instances error: run-instances carried no --client-token"
expect_nonzero "up commonframe-gate with an unrecognised run-instances error"
expect_run_count "up with an unrecognised run-instances error" 1
lookups=$(grep -F -- "Name=client-token,Values=$tok" "$STUB_REGION_LOG" | grep -c '^us-west-2 ')
[ "$lookups" -eq 6 ] || fail "up with an unrecognised run-instances error: want 6 lookups in us-west-2, got $lookups"
[ "$(grep -c -F 'Name=client-token' "$STUB_REGION_LOG")" -eq 6 ] || fail "up with an unrecognised run-instances error: lookups outside us-west-2"
expect_err "no instance was found for client token $tok in us-west-2" "up with an unrecognised run-instances error names the token and region"
expect_no_fixed "terminate-instances" "up with an unrecognised run-instances error terminates nothing"
if grep -F -q 'nothing was launched' "$ERR"; then
  fail "up with an unrecognised run-instances error still says nothing was launched"
fi
clear_faults

# A capacity refusal clears its token: the unrecognised error after it looks up only
# the failed attempt's token, and a launch with no failure looks up nothing.
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/other-error-us-west-2b"
run up commonframe-gate
first=$(client_token_of 1)
tok=$(client_token_of 2)
[ -n "$first" ] && [ -n "$tok" ] && [ "$first" != "$tok" ] || fail "up after a capacity refusal: attempts did not carry distinct client tokens"
expect_run_count "up after a capacity refusal" 2
expect_region "up after a capacity refusal looks up the failed attempt's token in us-west-2" us-west-2 \
  "Name=client-token,Values=$tok"
expect_no_region "up after a capacity refusal does not look up the refused attempt's token" us-west-2 \
  "Values=$first"
clear_faults

: >"$STUB_FIXTURES/no-capacity-us-west-2a"
run up commonframe-gate
expect_status 0 "up commonframe-gate after a capacity refusal"
expect_no_fixed "describe-instances" "up after a capacity refusal and a launch looks up no token"
clear_faults

# The walk's failed attempt is the fourth, in Ireland: each attempt carries its own
# client token, and the lookup filters on the failed attempt's token in eu-west-1
# alone.
for zone in us-west-2a us-west-2b us-west-2c; do
  : >"$STUB_FIXTURES/no-capacity-$zone"
done
: >"$STUB_FIXTURES/eu-west-1/timeout-eu-west-1a"
run up --type g4dn.xlarge --disk 40 --spot
expect_nonzero "spot up with run-instances timing out in eu-west-1a"
expect_run_count "spot up with run-instances timing out in eu-west-1a" 4
distinct=$(grep '^aws ec2 run-instances ' "$STUB_LOG" | grep -o -- '--client-token [^ ]*' | sort -u | wc -l)
[ "$distinct" -eq 4 ] || fail "spot up with run-instances timing out in eu-west-1a: want 4 distinct client tokens, got $distinct"
tok=$(client_token_of 4)
[ -n "$tok" ] || fail "spot up with run-instances timing out in eu-west-1a: run-instances carried no --client-token"
expect_region "spot up with run-instances timing out in eu-west-1a looks up the failed token in eu-west-1" eu-west-1 \
  "describe-instances" "Name=client-token,Values=$tok"
expect_no_region "spot up with run-instances timing out in eu-west-1a looks up no token in us-west-2" us-west-2 \
  "Name=client-token"
[ "$(grep -c -F 'Name=client-token' "$STUB_REGION_LOG")" -eq 1 ] || fail "spot up with run-instances timing out in eu-west-1a: want one lookup"
expect_region "spot up with run-instances timing out in eu-west-1a terminates the box in eu-west-1" eu-west-1 \
  "terminate-instances --instance-ids i-0launched00000001"
expect_terminated "spot up with run-instances timing out in eu-west-1a"
clear_faults

# The lookup interval is read as whole seconds, like the ready timeout.
export EC2_FLEET_LOOKUP_INTERVAL=soon
run up commonframe-gate
export EC2_FLEET_LOOKUP_INTERVAL=0
expect_nonzero "up with EC2_FLEET_LOOKUP_INTERVAL not whole seconds"
expect_err 'EC2_FLEET_LOOKUP_INTERVAL must be whole seconds' "up with EC2_FLEET_LOOKUP_INTERVAL not whole seconds names the knob"
expect_run_count "up with EC2_FLEET_LOOKUP_INTERVAL not whole seconds" 0

# The region walk: a type offered in both regions tries Oregon's spot zones, then
# Ireland's; then, for every launch, Oregon's on-demand zones and its unplaced
# attempt, then Ireland's. Ireland's attempts use Ireland's AMI and security
# group and run their AWS calls in eu-west-1.

# Every Oregon zone refused: the spot launch lands in Ireland's first zone.
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/no-capacity-us-west-2b"
: >"$STUB_FIXTURES/no-capacity-us-west-2c"
run up --type g4dn.xlarge --disk 40 --spot
expect_status 0 "spot up with every Oregon zone out of capacity"
expect_out '^market spot eu-west-1a$' "spot up with every Oregon zone out of capacity prints Ireland's market line"
expect_out '^ec2-[a-z0-9]{3} ready$' "spot up with every Oregon zone out of capacity prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_placements "spot up with every Oregon zone out of capacity" \
  "zone us-west-2a spot" "zone us-west-2b spot" "zone us-west-2c spot" "zone eu-west-1a spot"
expect_region "Ireland's launch uses Ireland's AMI and security group" eu-west-1 \
  "ec2 run-instances" "--image-id ami-irelandnew0002" "Groups=sg-0ireland0000001" "--placement AvailabilityZone=eu-west-1a"
expect_region "Ireland looks up its own AMI" eu-west-1 "ec2 describe-images"
expect_region "Ireland looks up its own security group" eu-west-1 "ec2 describe-security-groups"
expect_region "Ireland's launch is waited on in eu-west-1" eu-west-1 "ec2 wait instance-running --instance-ids i-0launched00000001"
expect_no_region "Oregon's AMI is never launched in Ireland" eu-west-1 "--image-id ami-newest00000002"
expect_no_region "Oregon launches nothing once every Oregon zone is refused" us-west-2 "wait instance-running"
expect_userdata "spot up with every Oregon zone out of capacity" "$name"
expect_no_fixed "terminate-instances" "spot up with every Oregon zone out of capacity terminates nothing on success"
clear_faults

# Ireland's launch fails its ssh probe: the one instance is terminated in eu-west-1.
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/no-capacity-us-west-2b"
: >"$STUB_FIXTURES/no-capacity-us-west-2c"
inject ssh-probe
export EC2_FLEET_READY_TIMEOUT=0
run up --type g4dn.xlarge --disk 40 --spot
expect_nonzero "spot up with Ireland's ssh probe failing"
expect_terminated "spot up with Ireland's ssh probe failing"
expect_region "Ireland's launch is terminated in eu-west-1" eu-west-1 \
  "ec2 terminate-instances --instance-ids i-0launched00000001"
expect_no_region "Oregon terminates nothing" us-west-2 "terminate-instances"
clear_faults
unset EC2_FLEET_READY_TIMEOUT

# Every spot zone in both regions throttled, Oregon cheaper: the next attempt is
# Oregon's first on-demand zone, and it launches there.
: >"$STUB_FIXTURES/throttle-spot-us-west-2a"
: >"$STUB_FIXTURES/throttle-spot-us-west-2b"
: >"$STUB_FIXTURES/throttle-spot-us-west-2c"
: >"$STUB_FIXTURES/eu-west-1/throttle-spot-eu-west-1a"
: >"$STUB_FIXTURES/eu-west-1/throttle-spot-eu-west-1b"
: >"$STUB_FIXTURES/eu-west-1/throttle-spot-eu-west-1c"
run up --type g4dn.xlarge --disk 20 --spot
expect_status 0 "spot up with every spot zone in both regions throttled"
expect_out '^market on-demand$' "spot up with every spot zone in both regions throttled prints the on-demand market line"
expect_out '^ec2-[a-z0-9]{3} ready$' "spot up with every spot zone in both regions throttled prints the ready line"
expect_placements "spot up with every spot zone in both regions throttled" \
  "zone us-west-2a spot" "zone us-west-2b spot" "zone us-west-2c spot" \
  "zone eu-west-1a spot" "zone eu-west-1b spot" "zone eu-west-1c spot" \
  "zone us-west-2a"
expect_region "Oregon's on-demand launch uses Oregon's AMI" us-west-2 \
  "ec2 run-instances" "--image-id ami-newest00000002" "--placement AvailabilityZone=us-west-2a"
clear_faults

# Oregon's spot quota is reached: its first spot attempt is refused with the quota
# error, the walk skips Oregon's other spot attempts and launches spot in Ireland's
# first zone. The stderr line names the market, the type and the region.
: >"$STUB_FIXTURES/quota-spot"
run up --type g4dn.xlarge --disk 40 --spot
expect_status 0 "spot up with Oregon's spot quota reached"
expect_out '^market spot eu-west-1a$' "spot up with Oregon's spot quota reached prints Ireland's market line"
expect_out '^ec2-[a-z0-9]{3} ready$' "spot up with Oregon's spot quota reached prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
[ "$(tail -n 1 "$OUT")" = "$name ready" ] || fail "spot up with Oregon's spot quota reached: the ready line is not last"
expect_err '^ec2: spot quota reached for g4dn\.xlarge in us-west-2; skipping its spot attempts there$' "spot up with Oregon's spot quota reached names the market, type and region"
expect_placements "spot up with Oregon's spot quota reached" "zone us-west-2a spot" "zone eu-west-1a spot"
expect_run_count "spot up with Oregon's spot quota reached" 2
expect_userdata "spot up with Oregon's spot quota reached" "$name"
expect_no_fixed "terminate-instances" "spot up with Oregon's spot quota reached terminates nothing on success"
clear_faults

# Oregon's on-demand vCPU quota is reached: its first on-demand attempt is refused
# with the quota error, the walk skips Oregon's other on-demand attempts, placed and
# unplaced, and launches in Ireland's first zone.
: >"$STUB_FIXTURES/quota-on-demand"
run up --type g4dn.xlarge --disk 20
expect_status 0 "on-demand up with Oregon's vCPU quota reached"
expect_no_fixed "--iam-instance-profile" "ad-hoc up launches with no instance profile"
expect_out '^market on-demand$' "on-demand up with Oregon's vCPU quota reached prints the on-demand market line"
expect_out '^ec2-[a-z0-9]{3} ready$' "on-demand up with Oregon's vCPU quota reached prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
[ "$(tail -n 1 "$OUT")" = "$name ready" ] || fail "on-demand up with Oregon's vCPU quota reached: the ready line is not last"
expect_err '^ec2: on-demand quota reached for g4dn\.xlarge in us-west-2; skipping its on-demand attempts there$' "on-demand up with Oregon's vCPU quota reached names the market, type and region"
expect_placements "on-demand up with Oregon's vCPU quota reached" "zone us-west-2a" "zone eu-west-1a"
expect_run_count "on-demand up with Oregon's vCPU quota reached" 2
expect_region "Ireland's launch after the quota uses Ireland's AMI and security group" eu-west-1 \
  "ec2 run-instances" "--image-id ami-irelandnew0002" "Groups=sg-0ireland0000001" "--placement AvailabilityZone=eu-west-1a"
expect_userdata "on-demand up with Oregon's vCPU quota reached" "$name"
expect_no_fixed "terminate-instances" "on-demand up with Oregon's vCPU quota reached terminates nothing on success"
clear_faults

# Spot quota reached in both regions: each region's spot attempts are skipped at
# their first refusal, and the walk moves on to Oregon's on-demand zone. Each region
# names its own quota line.
: >"$STUB_FIXTURES/quota-spot"
: >"$STUB_FIXTURES/eu-west-1/quota-spot"
run up --type g4dn.xlarge --disk 20 --spot
expect_status 0 "spot up with the spot quota reached in both regions"
expect_out '^market on-demand$' "spot up with the spot quota reached in both regions prints the on-demand market line"
expect_out '^ec2-[a-z0-9]{3} ready$' "spot up with the spot quota reached in both regions prints the ready line"
expect_placements "spot up with the spot quota reached in both regions" \
  "zone us-west-2a spot" "zone eu-west-1a spot" "zone us-west-2a"
expect_err '^ec2: spot quota reached for g4dn\.xlarge in us-west-2; skipping its spot attempts there$' "spot up with the spot quota reached in both regions names Oregon's quota"
expect_err '^ec2: spot quota reached for g4dn\.xlarge in eu-west-1; skipping its spot attempts there$' "spot up with the spot quota reached in both regions names Ireland's quota"
[ "$(grep -c 'quota reached' "$ERR")" -eq 2 ] || fail "spot up with the spot quota reached in both regions: want exactly two quota lines"
clear_faults

# commonframe-gate's spot quota is reached in Oregon, its only region: the spot
# attempts are skipped and the on-demand launch lands in Oregon's first zone.
: >"$STUB_FIXTURES/quota-spot"
run up commonframe-gate
expect_status 0 "up commonframe-gate with Oregon's spot quota reached"
expect_out '^market on-demand$' "up commonframe-gate with Oregon's spot quota reached prints the on-demand market line"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up commonframe-gate with Oregon's spot quota reached prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
[ "$(tail -n 1 "$OUT")" = "$name ready" ] || fail "up commonframe-gate with Oregon's spot quota reached: the ready line is not last"
expect_err '^ec2: spot quota reached for c8a\.4xlarge in us-west-2; skipping its spot attempts there$' "up commonframe-gate with Oregon's spot quota reached names the market, type and region"
expect_placements "up commonframe-gate with Oregon's spot quota reached" "zone us-west-2a spot" "zone us-west-2a"
expect_run_count "up commonframe-gate with Oregon's spot quota reached" 2
expect_userdata "up commonframe-gate with Oregon's spot quota reached" "$name"
expect_no_fixed "terminate-instances" "up commonframe-gate with Oregon's spot quota reached terminates nothing on success"
clear_faults

# On-demand: Oregon's zones and its unplaced attempt refused, so the launch lands
# in Ireland's first zone. The unplaced refusal names its region and the walk goes on.
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/no-capacity-us-west-2b"
: >"$STUB_FIXTURES/no-capacity-us-west-2c"
: >"$STUB_FIXTURES/no-capacity-unplaced"
run up --type g4dn.xlarge --disk 20
expect_status 0 "on-demand up with Oregon's zones and unplaced attempt refused"
expect_out '^market on-demand$' "on-demand up with Oregon's zones and unplaced attempt refused prints the on-demand market line"
expect_out '^ec2-[a-z0-9]{3} ready$' "on-demand up with Oregon's zones and unplaced attempt refused prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_placements "on-demand up with Oregon's zones and unplaced attempt refused" \
  "zone us-west-2a" "zone us-west-2b" "zone us-west-2c" "unplaced" "zone eu-west-1a"
expect_err 'no on-demand capacity for g4dn\.xlarge in us-west-2$' "on-demand up names the refused unplaced attempt by region"
expect_region "Ireland's on-demand launch uses Ireland's AMI and security group" eu-west-1 \
  "ec2 run-instances" "--image-id ami-irelandnew0002" "Groups=sg-0ireland0000001" "--placement AvailabilityZone=eu-west-1a"
expect_userdata "on-demand up with Oregon's zones and unplaced attempt refused" "$name"
expect_no_fixed "terminate-instances" "on-demand up with Oregon's zones and unplaced attempt refused terminates nothing on success"
clear_faults

# Every attempt in both regions refused: the launch stops with nothing launched,
# after every on-demand zone and unplaced attempt of both regions.
for dir in "$STUB_FIXTURES" "$STUB_FIXTURES/eu-west-1"; do
  for zone in us-west-2a us-west-2b us-west-2c eu-west-1a eu-west-1b eu-west-1c; do
    : >"$dir/no-capacity-$zone"
  done
  : >"$dir/no-capacity-unplaced"
done
run up --type g4dn.xlarge --disk 20
expect_nonzero "on-demand up with every attempt in both regions refused"
expect_err 'no region could launch g4dn\.xlarge; nothing was launched' "on-demand up with every attempt refused says nothing was launched"
expect_run_count "on-demand up with every attempt in both regions refused" 8
expect_no_fixed "terminate-instances" "on-demand up with every attempt refused terminates nothing"
clear_faults

# A type only Oregon offers: Ireland is asked for its zones and nothing else.
run up --type g6.xlarge --disk 40
expect_status 0 "on-demand up of a type only Oregon offers"
expect_out '^ec2-[a-z0-9]{3} ready$' "on-demand up of a type only Oregon offers prints the ready line"
expect_placements "on-demand up of a type only Oregon offers" "zone us-west-2a"
expect_region "Ireland is asked which zones offer the type" eu-west-1 \
  "ec2 describe-instance-type-offerings" "Values=g6.xlarge"
[ "$(grep -c '^eu-west-1 ' "$STUB_REGION_LOG")" -eq 1 ] || fail "on-demand up of a type only Oregon offers made more than the offering lookup in eu-west-1"
expect_no_log 'pricing get-products' "on-demand up of a type only Oregon offers looks up no price"

# A type neither region offers: the launch stops before the base AMI, Tailscale or run-instances.
run up --type p5.48xlarge --disk 40
expect_nonzero "up of a type no region offers"
expect_err 'no region offers p5\.48xlarge' "up of a type no region offers names it"
expect_no_fixed "describe-images" "up of a type no region offers looks up no AMI"
expect_no_fixed "api/v2" "up of a type no region offers asks Tailscale nothing"
expect_no_fixed "run-instances" "up of a type no region offers launches nothing"

# Ireland's on-demand g4dn.xlarge is cheaper than Oregon's: Ireland's first zone is
# the first on-demand attempt, and nothing is warned.
cat >"$STUB_FIXTURES/eu-west-1/pricing-g4dn.xlarge.json" <<'FIXTURE'
{"PriceList":["{\"terms\":{\"OnDemand\":{\"X\":{\"priceDimensions\":{\"Y\":{\"pricePerUnit\":{\"USD\":\"0.4000000000\"}}}}}}}"]}
FIXTURE
run up --type g4dn.xlarge --disk 20
expect_status 0 "on-demand up with Ireland cheaper"
expect_out '^ec2-[a-z0-9]{3} ready$' "on-demand up with Ireland cheaper prints the ready line"
expect_placements "on-demand up with Ireland cheaper" "zone eu-west-1a"
expect_region "Ireland's cheaper on-demand launch uses Ireland's AMI and security group" eu-west-1 \
  "ec2 run-instances" "--image-id ami-irelandnew0002" "Groups=sg-0ireland0000001"
if grep -q 'cannot rank' "$ERR"; then fail "on-demand up with Ireland cheaper warned that it cannot rank the regions"; fi

# Ireland's price lookup fails while Ireland is the cheaper: the walk keeps the
# fixed order, Oregon first, prints one warning, and launches in Oregon.
inject eu-west-1-pricing-get-products
run up --type g4dn.xlarge --disk 20
expect_status 0 "on-demand up with Ireland's price lookup failing"
expect_out '^ec2-[a-z0-9]{3} ready$' "on-demand up with Ireland's price lookup failing prints the ready line"
expect_err '^ec2: cannot rank regions by on-demand price for g4dn\.xlarge; trying them in fixed order$' "on-demand up with Ireland's price lookup failing warns once in fixed order"
[ "$(grep -c 'cannot rank' "$ERR")" -eq 1 ] || fail "on-demand up with Ireland's price lookup failing: want exactly one warning"
expect_placements "on-demand up with Ireland's price lookup failing" "zone us-west-2a"
expect_no_fixed "terminate-instances" "on-demand up with Ireland's price lookup failing terminates nothing on success"
clear_faults
cat >"$STUB_FIXTURES/eu-west-1/pricing-g4dn.xlarge.json" <<'FIXTURE'
{"PriceList":["{\"terms\":{\"OnDemand\":{\"X\":{\"priceDimensions\":{\"Y\":{\"pricePerUnit\":{\"USD\":\"0.6120000000\"}}}}}}}"]}
FIXTURE

# Ireland's base AMI is stale: Ireland alone builds and registers an image in
# eu-west-1, and prunes only its own two oldest base AMIs.
use_eu_images images-stale images-registered
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/no-capacity-us-west-2b"
: >"$STUB_FIXTURES/no-capacity-us-west-2c"
rebuild_run up --type g4dn.xlarge --disk 40 --spot
expect_status 0 "spot up with Ireland's base AMI stale"
expect_out '^market spot eu-west-1a$' "spot up with Ireland's base AMI stale prints Ireland's market line"
expect_out '^ec2-[a-z0-9]{3} ready$' "spot up with Ireland's base AMI stale prints the ready line"
expect_fixed "coldsnap --region eu-west-1 upload --wait --no-progress --tag Key=fleet,Value=ec2-base $STUB_FIXTURES/nixos.raw" "Ireland uploads its image in eu-west-1"
expect_region "Ireland registers its image in eu-west-1" eu-west-1 \
  "ec2 register-image" "--tag-specifications ResourceType=image,Tags=[{Key=fleet,Value=ec2-base},{Key=fleet-toplevel,Value=fixture-toplevel-base}]"
expect_region "Ireland waits for its new AMI in eu-west-1" eu-west-1 "ec2 wait image-available --image-ids ami-irelandnew0005"
expect_region "Ireland prunes its second-oldest AMI in eu-west-1" eu-west-1 "ec2 deregister-image --image-id ami-irestale-mid2"
expect_region "Ireland prunes its oldest AMI in eu-west-1" eu-west-1 "ec2 deregister-image --image-id ami-irestale-old1"
expect_region "Ireland deletes the snapshot of its second-oldest AMI" eu-west-1 "ec2 delete-snapshot --snapshot-id snap-0e1d00000000012"
expect_region "Ireland deletes the snapshot of its oldest AMI" eu-west-1 "ec2 delete-snapshot --snapshot-id snap-0e1d00000000011"
expect_no_region "Ireland keeps its two newest AMIs" eu-west-1 \
  "deregister-image --image-id ami-irestale-new3" "deregister-image --image-id ami-irelandnew0005" "delete-snapshot --snapshot-id snap-0e1d00000000013"
expect_no_region "Oregon's AMIs are untouched when only Ireland rebuilds" us-west-2 \
  "register-image" "deregister-image" "delete-snapshot"
expect_region "Ireland launches its new AMI in eu-west-1" eu-west-1 \
  "ec2 run-instances" "--image-id ami-irelandnew0005" "Groups=sg-0ireland0000001"
expect_order "Ireland's image steps run in order before its launch" \
  "coldsnap --region eu-west-1 upload" \
  "aws ec2 register-image" \
  "aws ec2 wait image-available --image-ids ami-irelandnew0005" \
  "aws ec2 deregister-image --image-id ami-irestale-mid2" \
  "--image-id ami-irelandnew0005"
clear_faults
use_eu_images images-full images-registered

# The spot walk orders the regions by spot placement score, from one score call
# in us-west-2 that names both offering regions. Each case sets the scores or
# prices it needs and restores the default fixtures afterwards.

# Ireland's score is higher: its first spot zone is the first attempt. No price is read.
cat >"$STUB_FIXTURES/scores-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPlacementScores":[{"Region":"us-west-2","Score":3},{"Region":"eu-west-1","Score":7}]}
FIXTURE
run up --type g4dn.xlarge --disk 40 --spot
expect_status 0 "spot up with Ireland's score higher"
expect_out '^market spot eu-west-1a$' "spot up with Ireland's score higher prints Ireland's market line"
expect_out '^ec2-[a-z0-9]{3} ready$' "spot up with Ireland's score higher prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_placements "spot up with Ireland's score higher" "zone eu-west-1a spot"
[ "$(grep -c '^aws ec2 get-spot-placement-scores ' "$STUB_LOG")" -eq 1 ] || fail "spot up with Ireland's score higher: want exactly one score call"
expect_region "spot up with Ireland's score higher asks the scores in us-west-2 for both regions" us-west-2 \
  "ec2 get-spot-placement-scores" "--region-names us-west-2 eu-west-1" "--instance-types g4dn.xlarge" "--target-capacity 1"
[ "$(grep -c '^eu-west-1 .*get-spot-placement-scores' "$STUB_REGION_LOG")" -eq 0 ] || fail "spot up with Ireland's score higher asks a score in eu-west-1"
expect_no_log "describe-spot-price-history" "spot up with Ireland's score higher reads no spot price"
if grep -q 'cannot' "$ERR"; then fail "spot up with Ireland's score higher warned"; fi
expect_userdata "spot up with Ireland's score higher" "$name"
expect_no_fixed "terminate-instances" "spot up with Ireland's score higher terminates nothing on success"
clear_faults
cat >"$STUB_FIXTURES/scores-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPlacementScores":[{"Region":"us-west-2","Score":5},{"Region":"eu-west-1","Score":5}]}
FIXTURE

# Scores tied and Ireland's spot price lower: Ireland's first spot zone is the first attempt.
cat >"$STUB_FIXTURES/eu-west-1/spot-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T07:00:00+00:00","SpotPrice":"0.1800","AvailabilityZone":"eu-west-1a"}]}
FIXTURE
run up --type g4dn.xlarge --disk 40 --spot
expect_status 0 "spot up with scores tied and Ireland's spot price lower"
expect_out '^market spot eu-west-1a$' "spot up with scores tied and Ireland's spot price lower prints Ireland's market line"
expect_placements "spot up with scores tied and Ireland's spot price lower" "zone eu-west-1a spot"
expect_region "scores tied: Oregon's spot price is read in us-west-2" us-west-2 \
  "describe-spot-price-history" "--instance-types g4dn.xlarge" "--availability-zone us-west-2c"
expect_region "scores tied: Ireland's spot price is read in eu-west-1" eu-west-1 \
  "describe-spot-price-history" "--instance-types g4dn.xlarge" "--availability-zone eu-west-1c"
if grep -q 'cannot' "$ERR"; then fail "spot up with scores tied and Ireland's spot price lower warned"; fi
clear_faults
cat >"$STUB_FIXTURES/eu-west-1/spot-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T07:00:00+00:00","SpotPrice":"0.2400","AvailabilityZone":"eu-west-1a"}]}
FIXTURE

# Scores tied and the spot prices equal: the fixed order holds, Oregon first.
cat >"$STUB_FIXTURES/eu-west-1/spot-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T07:00:00+00:00","SpotPrice":"0.2100","AvailabilityZone":"eu-west-1a"}]}
FIXTURE
run up --type g4dn.xlarge --disk 40 --spot
expect_status 0 "spot up with scores tied and spot prices equal"
expect_placements "spot up with scores tied and spot prices equal" "zone us-west-2a spot"
if grep -q 'cannot' "$ERR"; then fail "spot up with scores tied and spot prices equal warned"; fi
clear_faults
cat >"$STUB_FIXTURES/eu-west-1/spot-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T07:00:00+00:00","SpotPrice":"0.2400","AvailabilityZone":"eu-west-1a"}]}
FIXTURE

# Scores tied and Ireland's spot price has no history: the price cannot be read, so
# the fixed order holds, Oregon first, with one warning on stderr.
cat >"$STUB_FIXTURES/eu-west-1/spot-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPriceHistory":[]}
FIXTURE
run up --type g4dn.xlarge --disk 40 --spot
expect_status 0 "spot up with Ireland's spot price unreadable"
expect_err '^ec2: cannot break the spot score tie for g4dn\.xlarge by price; trying them in fixed order$' "spot up with Ireland's spot price unreadable warns once in fixed order"
[ "$(grep -c 'cannot break the spot score tie' "$ERR")" -eq 1 ] || fail "spot up with Ireland's spot price unreadable: want exactly one warning"
expect_placements "spot up with Ireland's spot price unreadable" "zone us-west-2a spot"
clear_faults
cat >"$STUB_FIXTURES/eu-west-1/spot-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPriceHistory":[{"Timestamp":"2026-10-27T07:00:00+00:00","SpotPrice":"0.2400","AvailabilityZone":"eu-west-1a"}]}
FIXTURE

# The score lookup fails: the spot walk keeps the fixed order, Oregon's zones then
# Ireland's, with one warning on stderr, and launches in Ireland's first zone.
inject ec2-get-spot-placement-scores
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/no-capacity-us-west-2b"
: >"$STUB_FIXTURES/no-capacity-us-west-2c"
run up --type g4dn.xlarge --disk 40 --spot
expect_status 0 "spot up with the score lookup failing"
expect_out '^market spot eu-west-1a$' "spot up with the score lookup failing prints Ireland's market line"
expect_err '^ec2: cannot rank regions by spot placement score for g4dn\.xlarge; trying them in fixed order$' "spot up with the score lookup failing warns in fixed order"
[ "$(grep -c 'cannot rank regions by spot' "$ERR")" -eq 1 ] || fail "spot up with the score lookup failing: want exactly one warning"
expect_placements "spot up with the score lookup failing" \
  "zone us-west-2a spot" "zone us-west-2b spot" "zone us-west-2c spot" "zone eu-west-1a spot"
clear_faults

# The score answer lacks Ireland's score: that counts as a failed lookup, so the
# walk keeps the fixed order and warns once. No price is read.
cat >"$STUB_FIXTURES/scores-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPlacementScores":[{"Region":"us-west-2","Score":3}]}
FIXTURE
run up --type g4dn.xlarge --disk 40 --spot
expect_status 0 "spot up with Ireland's score missing from the answer"
expect_err '^ec2: cannot rank regions by spot placement score for g4dn\.xlarge; trying them in fixed order$' "spot up with Ireland's score missing from the answer warns in fixed order"
[ "$(grep -c 'cannot rank regions by spot' "$ERR")" -eq 1 ] || fail "spot up with Ireland's score missing from the answer: want exactly one warning"
expect_placements "spot up with Ireland's score missing from the answer" "zone us-west-2a spot"
expect_no_log "describe-spot-price-history" "spot up with Ireland's score missing from the answer reads no spot price"
clear_faults
cat >"$STUB_FIXTURES/scores-g4dn.xlarge.json" <<'FIXTURE'
{"SpotPlacementScores":[{"Region":"us-west-2","Score":5},{"Region":"eu-west-1","Score":5}]}
FIXTURE

# Oregon-only types make no score call: commonframe-gate is a spot class and
# c8a.large is an ad-hoc spot type, and both are offered in Oregon alone.
use_images images-full images-registered-only
run up commonframe-gate
expect_status 0 "up commonframe-gate with no score call"
expect_no_log "get-spot-placement-scores" "up commonframe-gate makes no score call"
run up --type c8a.large --disk 40 --spot
expect_status 0 "ad-hoc spot up of an Oregon-only type"
expect_no_log "get-spot-placement-scores" "ad-hoc spot up of an Oregon-only type makes no score call"
clear_faults

# up --type --disk --spot: ad-hoc spot box, no deploy.
run up --type c8a.large --disk 40 --spot
expect_status 0 "ad-hoc spot up"
expect_out '^ec2-[a-z0-9]{3} ready$' "ad-hoc spot up prints the ready line"
expect_out '^market spot us-west-2a$' "ad-hoc spot up prints the spot market line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_fixed "--placement AvailabilityZone=us-west-2a" "ad-hoc spot up places the request in the first sorted zone"
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
expect_fixed "--placement AvailabilityZone=us-west-2a" "ad-hoc on-demand up places its first on-demand attempt in the first sorted zone"
expect_log 'describe-instance-type-offerings' "ad-hoc on-demand up lists zones"
expect_out '^market on-demand$' "ad-hoc on-demand up prints the on-demand market line"
expect_run_count "ad-hoc on-demand up" 1

# A warning on stderr from a successful run-instances is shown, and is not part
# of the instance id: the launched instance is the one waited on and kept.
: >"$STUB_FIXTURES/warn-run-instances"
run up --type m8a.large --disk 20
expect_status 0 "ad-hoc up with a warning from run-instances"
expect_err 'stub aws: a warning from run-instances' "ad-hoc up with a warning from run-instances shows the warning"
expect_fixed "aws ec2 wait instance-running --instance-ids i-0launched00000001" "ad-hoc up with a warning from run-instances waits for the launched instance"
expect_no_fixed "terminate-instances" "ad-hoc up with a warning from run-instances terminates nothing"

# With the launcher's stderr closed, relaying that warning fails after the
# launch, and the launched instance is still terminated.
: >"$STUB_LOG"
if "$EC2" up --type m8a.large --disk 20 >"$OUT" 2>&-; then STATUS=0; else STATUS=$?; fi
expect_nonzero "ad-hoc up with a warning from run-instances and stderr closed"
expect_terminated "ad-hoc up with a warning from run-instances and stderr closed"
clear_faults

# up muniment-runner: on-demand class with its own disk and max hours.
run up muniment-runner
expect_status 0 "up muniment-runner"
expect_out '^muniment-runner-[a-z0-9]{3} ready$' "up muniment-runner prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
expect_fixed "--instance-type m8a.2xlarge" "up muniment-runner sets its instance type"
expect_fixed "Ebs={VolumeSize=200,VolumeType=gp3,DeleteOnTermination=true}" "up muniment-runner sizes its root volume"
expect_fixed "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=fleet,Value=ec2},{Key=fleet-class,Value=muniment-runner},{Key=fleet-max-hours,Value=12}]" "up muniment-runner tags its max hours"
expect_no_fixed "--instance-market-options" "up muniment-runner requests no spot"
expect_fixed "--iam-instance-profile Name=ec2-fleet-cache" "up muniment-runner launches with the cache instance profile"
expect_fixed "--placement AvailabilityZone=us-west-2a" "up muniment-runner places its first on-demand attempt in the first sorted zone"
expect_log 'describe-instance-type-offerings' "up muniment-runner lists zones"
expect_out '^market on-demand$' "up muniment-runner prints the on-demand market line"
expect_run_count "up muniment-runner" 1
expect_fixed "nix copy --no-check-sigs --substitute-on-destination --to ssh-ng://joshsymonds@$name /nix/store/fixture-toplevel-muniment-runner" "up muniment-runner copies its own toplevel"
expect_fixed "joshsymonds@$name sudo /nix/store/fixture-toplevel-muniment-runner/bin/switch-to-configuration switch" "up muniment-runner switches its own toplevel"

# An in-place switch of a cache class that exits 4 with only ec2-s3-cache failed
# keeps the box up cold: one stderr line names the cold cache, and the ready line
# is still last on stdout.
printf '4\n' >"$STUB_FIXTURES/switch-status"
printf 'ec2-s3-cache.service loaded failed failed S3 cache mount\n' >"$STUB_FIXTURES/failed-units"
run up muniment-runner
expect_status 0 "up muniment-runner with the switch exiting 4 and only ec2-s3-cache failed"
expect_err 'cold cache' "up muniment-runner with the switch exiting 4 and only ec2-s3-cache failed names the cold cache"
expect_no_fixed "terminate-instances" "up muniment-runner with the switch exiting 4 and only ec2-s3-cache failed keeps the box"
expect_fixed "systemctl list-units --state=failed --plain --no-legend --no-pager" "up muniment-runner with the switch exiting 4 queries the failed units"
expect_out '^muniment-runner-[a-z0-9]{3} ready$' "up muniment-runner with the switch exiting 4 and only ec2-s3-cache failed prints the ready line"
name2=$(sed -n 's/ ready$//p' "$OUT")
[ "$(tail -n 1 "$OUT")" = "$name2 ready" ] || fail "up muniment-runner with the switch exiting 4 and only ec2-s3-cache failed: the ready line is not last"

# Exit 4 with another unit failed too is a real switch failure: the box dies.
printf 'ec2-s3-cache.service loaded failed failed S3 cache mount\nsshd.service loaded failed failed OpenSSH\n' >"$STUB_FIXTURES/failed-units"
run up muniment-runner
expect_nonzero "up muniment-runner with the switch exiting 4 and another unit failed"
expect_terminated "up muniment-runner with the switch exiting 4 and another unit failed"

# Exit 4 with no failed unit listed is a real switch failure too.
printf '' >"$STUB_FIXTURES/failed-units"
run up muniment-runner
expect_nonzero "up muniment-runner with the switch exiting 4 and no unit failed"
expect_terminated "up muniment-runner with the switch exiting 4 and no unit failed"

# Any other switch exit status is a real switch failure, even when only
# ec2-s3-cache failed.
printf 'ec2-s3-cache.service loaded failed failed S3 cache mount\n' >"$STUB_FIXTURES/failed-units"
printf '1\n' >"$STUB_FIXTURES/switch-status"
run up muniment-runner
expect_nonzero "up muniment-runner with the switch exiting 1"
expect_terminated "up muniment-runner with the switch exiting 1"

# A failed failed-unit query after exit 4 is a real switch failure.
printf '4\n' >"$STUB_FIXTURES/switch-status"
inject ssh-failed-units
run up muniment-runner
expect_nonzero "up muniment-runner with the failed-unit query failing"
expect_terminated "up muniment-runner with the failed-unit query failing"
clear_faults

# A class without cache is a real switch failure even when only ec2-s3-cache
# failed.
printf '4\n' >"$STUB_FIXTURES/switch-status"
printf 'ec2-s3-cache.service loaded failed failed S3 cache mount\n' >"$STUB_FIXTURES/failed-units"
run up commonframe-gate
expect_nonzero "up commonframe-gate with the switch exiting 4 and only ec2-s3-cache failed"
expect_terminated "up commonframe-gate with the switch exiting 4 and only ec2-s3-cache failed"
clear_faults

# up muniment-runner with Ireland offering m8a.2xlarge too, Oregon cheaper, and every
# Oregon on-demand attempt refused: the walk takes Oregon's zones and unplaced
# attempt, then Ireland's first zone.
cat >"$STUB_FIXTURES/eu-west-1/offerings-m8a.2xlarge.json" <<'FIXTURE'
{"InstanceTypeOfferings":[
{"InstanceType":"m8a.2xlarge","Location":"eu-west-1c","LocationType":"availability-zone"},
{"InstanceType":"m8a.2xlarge","Location":"eu-west-1a","LocationType":"availability-zone"},
{"InstanceType":"m8a.2xlarge","Location":"eu-west-1b","LocationType":"availability-zone"}
]}
FIXTURE
cat >"$STUB_FIXTURES/eu-west-1/pricing-m8a.2xlarge.json" <<'FIXTURE'
{"PriceList":["{\"terms\":{\"OnDemand\":{\"X\":{\"priceDimensions\":{\"Y\":{\"pricePerUnit\":{\"USD\":\"0.4500000000\"}}}}}}}"]}
FIXTURE
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/no-capacity-us-west-2b"
: >"$STUB_FIXTURES/no-capacity-us-west-2c"
: >"$STUB_FIXTURES/no-capacity-unplaced"
run up muniment-runner
expect_status 0 "up muniment-runner with Oregon's on-demand walk refused"
expect_out '^market on-demand$' "up muniment-runner with Oregon's on-demand walk refused prints the on-demand market line"
expect_out '^muniment-runner-[a-z0-9]{3} ready$' "up muniment-runner with Oregon's on-demand walk refused prints the ready line"
expect_placements "up muniment-runner with Oregon's on-demand walk refused" \
  "zone us-west-2a" "zone us-west-2b" "zone us-west-2c" "unplaced" "zone eu-west-1a"
expect_region "up muniment-runner's Ireland launch uses Ireland's AMI and security group" eu-west-1 \
  "ec2 run-instances" "--image-id ami-irelandnew0002" "Groups=sg-0ireland0000001" "--placement AvailabilityZone=eu-west-1a"
clear_faults
echo '{"InstanceTypeOfferings":[]}' >"$STUB_FIXTURES/eu-west-1/offerings-m8a.2xlarge.json"
rm -f "$STUB_FIXTURES/eu-west-1/pricing-m8a.2xlarge.json"

# up reboot-probe: a class with reboot = true deploys with switch-to-configuration
# boot, reboots the box and waits for a new boot id, and prints the ready line last.
TL_REBOOT=/nix/store/fixture-toplevel-reboot-probe
run up reboot-probe
expect_status 0 "up reboot-probe"
expect_out '^reboot-probe-[a-z0-9]{3} ready$' "up reboot-probe prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
[ "$(tail -n 1 "$OUT")" = "$name ready" ] || fail "up reboot-probe: the ready line is not the last stdout line"
expect_fixed "nix build --no-link --print-out-paths /fixture/flake#nixosConfigurations.ec2-reboot-probe.config.system.build.toplevel" "up reboot-probe builds its class toplevel"
expect_userdata "up reboot-probe" "$name"
expect_no_fixed "switch-to-configuration switch" "up reboot-probe switches nothing in place"
expect_order "up reboot-probe orders copy, profile, boot id read, boot switch, reboot" \
  "nix copy --no-check-sigs --substitute-on-destination --to ssh-ng://joshsymonds@$name $TL_REBOOT" \
  "joshsymonds@$name sudo nix-env -p /nix/var/nix/profiles/system --set $TL_REBOOT" \
  "joshsymonds@$name cat /proc/sys/kernel/random/boot_id" \
  "joshsymonds@$name sudo $TL_REBOOT/bin/switch-to-configuration boot" \
  "joshsymonds@$name sudo systemctl reboot"
reboot_line=$(grep -F -n -- "joshsymonds@$name sudo systemctl reboot" "$STUB_LOG" | cut -d: -f1)
boot_reads=$(grep -F -c -- "joshsymonds@$name cat /proc/sys/kernel/random/boot_id" "$STUB_LOG")
last_boot_line=$(grep -F -n -- "joshsymonds@$name cat /proc/sys/kernel/random/boot_id" "$STUB_LOG" | tail -n 1 | cut -d: -f1)
if [ "$boot_reads" -ne 2 ] || [ -z "$reboot_line" ] || [ "$last_boot_line" -le "$reboot_line" ]; then
  fail "up reboot-probe: want two boot id reads, the second after the reboot request"
fi
mux_calls=$(grep -E '^ssh ' "$STUB_LOG" | grep -F -- "joshsymonds@$name")
[ "$(printf '%s\n' "$mux_calls" | grep -c .)" -eq 6 ] || fail "up reboot-probe made an unexpected number of ssh calls to $name"
while IFS= read -r call; do
  case $call in *"-o ControlMaster=no"*) ;; *) fail "up reboot-probe: ssh call without ControlMaster=no: $call" ;; esac
  case $call in *"-o ControlPath=none"*) ;; *) fail "up reboot-probe: ssh call without ControlPath=none: $call" ;; esac
done <<<"$mux_calls"
# Every call on the reboot path is bounded on the client side, so a connection
# that never answers or goes silent ends the call.
bounded_calls=$(printf '%s\n' "$mux_calls" | grep -E 'boot_id|switch-to-configuration boot|systemctl reboot')
[ "$(printf '%s\n' "$bounded_calls" | grep -c .)" -eq 4 ] || fail "up reboot-probe: want four reboot-path ssh calls to $name"
while IFS= read -r call; do
  for opt in ConnectTimeout= ServerAliveInterval= ServerAliveCountMax=; do
    case $call in *"-o $opt"*) ;; *) fail "up reboot-probe: reboot-path ssh call without -o $opt: $call" ;; esac
  done
done <<<"$bounded_calls"
expect_no_fixed "terminate-instances" "up reboot-probe terminates nothing on success"

# The reboot request's ssh exit status does not fail the launch: the new boot id
# is the evidence.
inject ssh-reboot
run up reboot-probe
expect_status 0 "up reboot-probe with the reboot request failing"
expect_out '^reboot-probe-[a-z0-9]{3} ready$' "up reboot-probe with the reboot request failing prints the ready line"
expect_no_fixed "terminate-instances" "up reboot-probe with the reboot request failing terminates nothing"
clear_faults

# A box that answers the old boot id to its first two polls after the reboot is
# polled again until a new one answers. Three reads after the reboot request
# prove the wait loops rather than reading once; the launch ends ready. The
# launcher's 5 s poll interval makes this case take about 10 s.
printf '2\n' >"$STUB_FIXTURES/boot-id-lag"
export EC2_FLEET_READY_TIMEOUT=60
run up reboot-probe
expect_status 0 "up reboot-probe with two stale boot id polls"
expect_out '^reboot-probe-[a-z0-9]{3} ready$' "up reboot-probe with two stale boot id polls prints the ready line"
name=$(sed -n 's/ ready$//p' "$OUT")
[ "$(tail -n 1 "$OUT")" = "$name ready" ] || fail "up reboot-probe with two stale boot id polls: the ready line is not the last stdout line"
reboot_line=$(grep -F -n -- "joshsymonds@$name sudo systemctl reboot" "$STUB_LOG" | cut -d: -f1)
polls=$(tail -n +"$((reboot_line + 1))" "$STUB_LOG" | grep -F -c -- "joshsymonds@$name cat /proc/sys/kernel/random/boot_id")
[ "$polls" -eq 3 ] || fail "up reboot-probe with two stale boot id polls: want three polls after the reboot request, got $polls"
expect_no_fixed "terminate-instances" "up reboot-probe with two stale boot id polls terminates nothing"
unset EC2_FLEET_READY_TIMEOUT
rm -f "$STUB_FIXTURES/boot-id-lag"

# A reboot class whose box never reports a new boot id fails within the timeout,
# after the reboot request, and terminates the box.
export EC2_FLEET_READY_TIMEOUT=0
printf '%s\n' "$BOOT_BEFORE" >"$STUB_FIXTURES/boot-id-after"
run up reboot-probe
expect_nonzero "up reboot-probe whose boot id never changes"
expect_terminated "up reboot-probe whose boot id never changes"
expect_no_out ' ready$' "up reboot-probe whose boot id never changes prints no ready line"
expect_fixed "sudo systemctl reboot" "up reboot-probe whose boot id never changes requests the reboot"
printf '%s\n' "$BOOT_AFTER" >"$STUB_FIXTURES/boot-id-after"

# An empty boot id after the reboot is not evidence of a new boot.
: >"$STUB_FIXTURES/boot-id-after"
run up reboot-probe
expect_nonzero "up reboot-probe with an empty boot id after the reboot"
expect_terminated "up reboot-probe with an empty boot id after the reboot"
expect_no_out ' ready$' "up reboot-probe with an empty boot id after the reboot prints no ready line"
printf '%s\n' "$BOOT_AFTER" >"$STUB_FIXTURES/boot-id-after"
unset EC2_FLEET_READY_TIMEOUT

# A failed or empty boot id read before the reboot stops before the switch.
inject ssh-boot-id
run up reboot-probe
expect_nonzero "up reboot-probe with the boot id read failing"
expect_terminated "up reboot-probe with the boot id read failing"
expect_no_fixed "switch-to-configuration" "up reboot-probe with the boot id read failing switches nothing"
expect_no_fixed "systemctl reboot" "up reboot-probe with the boot id read failing reboots nothing"
clear_faults
: >"$STUB_FIXTURES/boot-id-before"
run up reboot-probe
expect_nonzero "up reboot-probe with an empty boot id before the reboot"
expect_terminated "up reboot-probe with an empty boot id before the reboot"
expect_no_fixed "switch-to-configuration" "up reboot-probe with an empty boot id before the reboot switches nothing"
printf '%s\n' "$BOOT_BEFORE" >"$STUB_FIXTURES/boot-id-before"

# A failed boot switch stops before the reboot request and terminates the box.
inject ssh-switch-boot
run up reboot-probe
expect_nonzero "up reboot-probe with the boot switch failing"
expect_terminated "up reboot-probe with the boot switch failing"
expect_no_fixed "systemctl reboot" "up reboot-probe with the boot switch failing reboots nothing"
expect_no_fixed "switch-to-configuration switch" "up reboot-probe with the boot switch failing switches in place"
clear_faults

# A box whose running wait fails is terminated once, in its region, and the walk
# goes on with a fresh name, key and user-data. Attempt 1 is us-west-2a's spot
# launch, whose running wait fails once; attempt 2, us-west-2b's spot launch,
# reaches running, and the launch ends ready with the market line of that box.
echo 1 >"$STUB_FIXTURES/running-fail-left"
run up commonframe-gate
expect_status 0 "up commonframe-gate with attempt 1's running wait failing once"
expect_out '^market spot us-west-2b$' "up with attempt 1's running wait failing once prints the market line of the box that ran"
[ "$(grep -c '^market ' "$OUT")" -eq 1 ] || fail "up with attempt 1's running wait failing once: want exactly one market line"
expect_out '^commonframe-gate-[a-z0-9]{3} ready$' "up with attempt 1's running wait failing once prints the ready line"
name2=$(sed -n 's/ ready$//p' "$OUT")
[ "$(tail -n 1 "$OUT")" = "$name2 ready" ] || fail "up with attempt 1's running wait failing once: the ready line is not last"
expect_err '^ec2: i-0launched00000001 did not reach running in us-west-2; terminated it$' "up with attempt 1's running wait failing once names the terminated box and region"
expect_placements "up with attempt 1's running wait failing once" "zone us-west-2a spot" "zone us-west-2b spot"
expect_run_count "up with attempt 1's running wait failing once" 2
expect_terminated "up with attempt 1's running wait failing once"
expect_region "up with attempt 1's running wait failing once terminates attempt 1's box in us-west-2" us-west-2 \
  "terminate-instances --instance-ids i-0launched00000001"
expect_no_region "up with attempt 1's running wait failing once terminates nothing in eu-west-1" eu-west-1 "terminate-instances"
first_wait=$(grep -F -n -m1 -- 'aws ec2 wait instance-running' "$STUB_LOG" | cut -d: -f1)
term_line=$(grep -F -n -m1 -- 'terminate-instances --instance-ids i-0launched00000001' "$STUB_LOG" | cut -d: -f1)
second_run=$(grep -E -n '^aws ec2 run-instances ' "$STUB_LOG" | sed -n 2p | cut -d: -f1)
if [ -z "$first_wait" ] || [ -z "$term_line" ] || [ -z "$second_run" ] ||
  [ "$term_line" -le "$first_wait" ] || [ "$second_run" -le "$term_line" ]; then
  fail "up with attempt 1's running wait failing once: want attempt 1's running wait, then its terminate, then attempt 2's run-instances"
fi
name1=$(sed -n 's/^EC2_FLEET_NAME=//p' "$STUB_FIXTURES/user-data.1.seen" 2>/dev/null)
name2_ud=$(sed -n 's/^EC2_FLEET_NAME=//p' "$STUB_FIXTURES/user-data.2.seen" 2>/dev/null)
[ "$name2_ud" = "$name2" ] || fail "up with attempt 1's running wait failing once: the ready box is not attempt 2's name"
if [ -z "$name1" ] || [ "$name1" = "$name2" ]; then
  fail "up with attempt 1's running wait failing once: attempt 2 reuses attempt 1's name"
fi
expect_attempt_userdata "up with attempt 1's running wait failing once: attempt 1" 1 "$name1" "$AUTHKEY"
expect_attempt_userdata "up with attempt 1's running wait failing once: attempt 2" 2 "$name2" "$AUTHKEY-2"
clear_faults

# Every placed attempt refused, so the unplaced launch is the last attempt, and its
# running wait fails. Nothing is left running: that box is terminated once, nothing
# is printed as the launched box, and the launch exits nonzero.
: >"$STUB_FIXTURES/no-capacity-us-west-2a"
: >"$STUB_FIXTURES/no-capacity-us-west-2b"
: >"$STUB_FIXTURES/no-capacity-us-west-2c"
echo 1 >"$STUB_FIXTURES/running-fail-left"
run up commonframe-gate
expect_nonzero "up commonframe-gate with the running wait failing on the last attempt"
expect_err 'no region could launch c8a\.4xlarge; nothing was launched' "up with the running wait failing on the last attempt names the exhausted walk"
expect_run_count "up with the running wait failing on the last attempt" 7
expect_placements "up with the running wait failing on the last attempt" \
  "zone us-west-2a spot" "zone us-west-2b spot" "zone us-west-2c spot" \
  "zone us-west-2a" "zone us-west-2b" "zone us-west-2c" "unplaced"
expect_terminated "up with the running wait failing on the last attempt"
expect_region "up with the running wait failing on the last attempt terminates its box in us-west-2" us-west-2 \
  "terminate-instances --instance-ids i-0launched00000001"
expect_no_out ' ready$' "up with the running wait failing on the last attempt prints no ready line"
expect_no_out '^market ' "up with the running wait failing on the last attempt prints no market line"
expect_no_fixed "nix copy" "up with the running wait failing on the last attempt copies nothing"
clear_faults

# A failure after run-instances terminates the launched instance and exits nonzero.
# A persistent running-wait failure fails every attempt: each run-instances call's
# box is terminated once, and the walk ends.
export EC2_FLEET_READY_TIMEOUT=0
for fault in ec2-wait ssh-probe nix-copy ssh-nix-env ssh-switch; do
  inject "$fault"
  run up commonframe-gate
  expect_nonzero "up commonframe-gate with $fault failing"
  if [ "$fault" = ec2-wait ]; then
    expect_run_count "up commonframe-gate with ec2-wait failing" 7
    expect_terminations "up commonframe-gate with ec2-wait failing" 7
  else
    expect_terminated "up commonframe-gate with $fault failing"
  fi
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
  if [ "$fault" = ec2-wait ]; then
    expect_run_count "ad-hoc up with ec2-wait failing" 5
    expect_terminations "ad-hoc up with ec2-wait failing" 5
  else
    expect_terminated "ad-hoc up with $fault failing"
  fi
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

# An interrupt after run-instances, during the ssh readiness probe, terminates the
# launched instance once and exits nonzero. The probe succeeds once released, so
# a launcher that ignores the signal would finish the launch and exit 0.
for sig in TERM INT HUP; do
  probe_signal=$sig
  run up commonframe-gate
  probe_signal=
  expect_nonzero "up commonframe-gate with SIG$sig during the ssh probe"
  expect_terminated "up commonframe-gate with SIG$sig during the ssh probe"
done

# A signal during run-instances. The held call returns a box: the launcher exits
# nonzero after that one call, before the running wait, and on_exit terminates the
# box by its id once. INT also goes to the launcher's process group, so the call
# must survive it.
for sig in TERM INT HUP; do
  if [ "$sig" = INT ]; then signal_group=yes; fi
  run_signal=$sig
  run up commonframe-gate
  run_signal=
  signal_group=
  expect_nonzero "up commonframe-gate with SIG$sig during a run-instances call that returns a box"
  expect_terminated "up commonframe-gate with SIG$sig during a run-instances call that returns a box"
  expect_run_count "up commonframe-gate with SIG$sig during a run-instances call that returns a box" 1
  expect_no_fixed "wait instance-running" "up commonframe-gate with SIG$sig during a run-instances call that returns a box"
done

# The held call is refused for capacity: it launched nothing, so the launcher exits
# after that one call and terminates nothing.
for sig in TERM INT HUP; do
  if [ "$sig" = INT ]; then signal_group=yes; fi
  : >"$STUB_FIXTURES/no-capacity-us-west-2a"
  run_signal=$sig
  run up commonframe-gate
  run_signal=
  signal_group=
  clear_faults
  expect_nonzero "up commonframe-gate with SIG$sig during a run-instances call refused for capacity"
  expect_run_count "up commonframe-gate with SIG$sig during a run-instances call refused for capacity" 1
  expect_no_fixed "terminate-instances" "up commonframe-gate with SIG$sig during a run-instances call refused for capacity"
done

# A signal during the terminate of a box whose running wait failed. The terminate is
# held, and TERM goes to the launcher and its process group, so the held terminate
# does not finish. The box is still ended: a terminate completes after the hold, and
# the launch exits nonzero.
echo 1 >"$STUB_FIXTURES/running-fail-left"
: >"$STUB_FIXTURES/hold-terminate-instances"
terminate_signal=TERM
signal_group=yes
run up commonframe-gate
terminate_signal=
signal_group=
rm -f "$STUB_FIXTURES/hold-terminate-instances"
clear_faults
expect_nonzero "up commonframe-gate with SIG TERM during the terminate of a box whose running wait failed"
done_count=$(grep -c -x 'i-0launched00000001' "$STUB_FIXTURES/terminated" 2>/dev/null) || done_count=0
[ "$done_count" -ge 1 ] || fail "up commonframe-gate with SIG TERM during the terminate of a box whose running wait failed: no terminate of i-0launched00000001 completed"
rm -f "$STUB_FIXTURES/terminated"

# A TERM at the first command after the launcher records the box's id still ends
# the box in its own region. BASH_ENV gives the launcher a DEBUG trap that sends the
# signal the moment launched is set, before anything else the launcher does.
cat >"$work/term-after-id.bash" <<'BASHENV'
set -T
trap 'if [ -n "${launched:-}" ] && [ -z "${term_after_id_sent:-}" ]; then term_after_id_sent=1; kill -s TERM "$$"; fi' DEBUG
BASHENV
export BASH_ENV="$work/term-after-id.bash"
run up commonframe-gate
unset BASH_ENV
expect_nonzero "up commonframe-gate with SIG TERM right after the box id is recorded"
expect_terminated "up commonframe-gate with SIG TERM right after the box id is recorded"
grep -q -F -x 'us-west-2 ec2 terminate-instances --instance-ids i-0launched00000001' "$STUB_REGION_LOG" ||
  fail "up commonframe-gate with SIG TERM right after the box id is recorded: no terminate of i-0launched00000001 in us-west-2"

if [ "$failures" -ne 0 ]; then
  echo "ec2 stubbed test: $failures check(s) failed" >&2
  exit 1
fi
echo "ec2 stubbed test: all checks passed"
