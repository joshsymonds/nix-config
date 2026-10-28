#!/usr/bin/env bash
# Stubbed test for the ec2 launcher. Usage: test.sh <path-to-ec2-binary>.
# The launcher runs with stub aws, nix, coldsnap, curl and ssh on PATH; each
# stub appends its argv to $STUB_LOG. No network access is made.
set -uo pipefail

EC2=$1
work=$(mktemp -d)
STUB_LOG="$work/calls.log"
STUB_FIXTURES="$work/fixtures"
OUT="$work/stdout"
ERR="$work/stderr"
ENV_FILE="$work/aws.env"
SECRET="SECRET-STUB-VALUE-7f3a9c"
export STUB_LOG STUB_FIXTURES
export PATH="$work/bin:$PATH"
export EC2_FLEET_FLAKE=/fixture/flake
mkdir -p "$work/bin" "$STUB_FIXTURES"
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

write_stub aws <<'STUB'
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
  terminate-instances) echo '{"TerminatingInstances":[]}' ;;
  *)
    echo "stub aws: unexpected ec2 subcommand $2" >&2
    exit 1
    ;;
esac
STUB

write_stub nix <<'STUB'
[ "$1" = eval ] || {
  echo "stub nix: unexpected subcommand $1" >&2
  exit 1
}
cat "$STUB_FIXTURES/classes.json"
STUB

for tool in coldsnap curl ssh; do
  write_stub "$tool" <<'STUB'
echo "unexpected call to a stub that must not run" >&2
exit 99
STUB
done

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

printf 'AWS_ACCESS_KEY_ID=AKIASTUBKEY0001\nAWS_SECRET_ACCESS_KEY=%s\n' "$SECRET" >"$ENV_FILE"

# run <ec2 args...>: runs the launcher, sets STATUS/OUT/ERR, resets the call log.
run() {
  : >"$STUB_LOG"
  if "$EC2" "$@" >"$OUT" 2>"$ERR"; then
    STATUS=0
  else
    STATUS=$?
  fi
  if grep -F -q -- "$SECRET" "$OUT" "$ERR" "$STUB_LOG"; then
    fail "secret value appeared in launcher output or a stub's argv ($*)"
  fi
  if grep -E -q '^(coldsnap|curl|ssh) ' "$STUB_LOG"; then
    fail "launcher called a stub that must not run ($*)"
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

# up is not built yet: it must say so and make no AWS call.
run up commonframe-gate
expect_nonzero "up"
expect_err 'not implemented' "up says it is not implemented"
expect_no_log '.' "up makes no stub call"

if [ "$failures" -ne 0 ]; then
  echo "ec2 stubbed test: $failures check(s) failed" >&2
  exit 1
fi
echo "ec2 stubbed test: all checks passed"
