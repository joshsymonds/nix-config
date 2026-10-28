# ec2: launch, list, and terminate fleet boxes in us-west-2.
# AWS credentials come only from $EC2_FLEET_AWS_ENV_FILE and are never printed
# or placed on a command line.

region=us-west-2
flake=${EC2_FLEET_FLAKE:-$HOME/nix-config}

die() {
  echo "ec2: $*" >&2
  exit 1
}

load_aws_env() {
  local key value access="" secret=""
  [ -n "${EC2_FLEET_AWS_ENV_FILE:-}" ] || die "EC2_FLEET_AWS_ENV_FILE is not set"
  [ -r "$EC2_FLEET_AWS_ENV_FILE" ] || die "cannot read $EC2_FLEET_AWS_ENV_FILE"
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      AWS_ACCESS_KEY_ID) access=$value ;;
      AWS_SECRET_ACCESS_KEY) secret=$value ;;
    esac
  done <"$EC2_FLEET_AWS_ENV_FILE"
  if [ -z "$access" ] || [ -z "$secret" ]; then
    die "$EC2_FLEET_AWS_ENV_FILE lacks AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY"
  fi
  export AWS_ACCESS_KEY_ID=$access AWS_SECRET_ACCESS_KEY=$secret AWS_DEFAULT_REGION=$region
}

# age_of <launch time>: elapsed time since launch as <h>h<mm>m.
age_of() {
  local launched now secs
  launched=$(date -d "$1" +%s)
  now=$(date +%s)
  secs=$((now - launched))
  printf '%dh%02dm' $((secs / 3600)) $((secs % 3600 / 60))
}

# on_demand_price <type>: Linux on-demand $/hr in us-west-2.
on_demand_price() {
  aws pricing get-products --region us-east-1 --service-code AmazonEC2 --output json \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$1" \
    "Type=TERM_MATCH,Field=regionCode,Value=$region" \
    "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
    "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
    "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
    "Type=TERM_MATCH,Field=capacitystatus,Value=Used" |
    jq -r '[.PriceList[] | fromjson | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD] | first // "n/a"'
}

# spot_price <type> <az>: newest Linux spot $/hr for the type in the zone.
spot_price() {
  aws ec2 describe-spot-price-history --output json --instance-types "$1" \
    --availability-zone "$2" --product-descriptions 'Linux/UNIX' |
    jq -r '.SpotPriceHistory | max_by(.Timestamp).SpotPrice // "n/a"'
}

cmd_ls() {
  local described rows name class itype spot launch az od sp
  load_aws_env
  described=$(aws ec2 describe-instances --output json \
    --filters 'Name=tag:fleet,Values=ec2' 'Name=instance-state-name,Values=pending,running')
  rows=$(jq -r '
    def tag($k): [.Tags[]? | select(.Key == $k) | .Value][0] // "";
    .Reservations[].Instances[]
    | select(.State.Name == "pending" or .State.Name == "running")
    | select(tag("fleet") == "ec2")
    | [tag("Name"), tag("fleet-class"), .InstanceType,
       (if .InstanceLifecycle == "spot" then "yes" else "no" end),
       .LaunchTime, .Placement.AvailabilityZone]
    | @tsv' <<<"$described")
  printf '%-28s %-18s %-14s %-5s %-8s %-13s %s\n' NAME CLASS TYPE SPOT AGE ON-DEMAND/HR SPOT/HR
  if [ -z "$rows" ]; then
    return 0
  fi
  while IFS=$'\t' read -r name class itype spot launch az; do
    od=$(on_demand_price "$itype") || die "pricing lookup failed for $itype"
    sp=$(spot_price "$itype" "$az") || die "spot price lookup failed for $itype in $az"
    printf '%-28s %-18s %-14s %-5s %-8s %-13s %s\n' "$name" "$class" "$itype" "$spot" \
      "$(age_of "$launch")" "$od" "$sp"
  done <<<"$rows"
}

cmd_down() {
  local name described ids
  [ $# -eq 1 ] || die "usage: ec2 down <name>"
  name=$1
  load_aws_env
  described=$(aws ec2 describe-instances --output json \
    --filters "Name=tag:Name,Values=$name" 'Name=tag:fleet,Values=ec2' \
    'Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down')
  ids=$(jq -r --arg name "$name" '
    def tag($k): [.Tags[]? | select(.Key == $k) | .Value][0] // "";
    .Reservations[].Instances[]
    | select(.State.Name != "terminated")
    | select(tag("fleet") == "ec2" and tag("Name") == $name)
    | .InstanceId' <<<"$described")
  if [ -z "$ids" ]; then
    die "no fleet box named $name"
  fi
  case "$ids" in
    *$'\n'*) die "more than one fleet box named $name; refusing to terminate" ;;
  esac
  aws ec2 terminate-instances --instance-ids "$ids" >/dev/null
  echo "terminating $ids ($name)"
}

cmd_help() {
  local classes
  classes=$(nix eval --json "$flake#ec2Classes")
  cat <<'USAGE'
ec2 - launch, list, and terminate fleet boxes in us-west-2

Usage:
  ec2 up <class>                          start a box of a class
  ec2 up --type <t> --disk <gb> [--spot]  start an ad-hoc box
  ec2 ls                                  list pending and running fleet boxes
  ec2 down <name>                         terminate a fleet box
  ec2 help                                show this help

Flags:
  --type <t>    EC2 instance type for an ad-hoc box
  --disk <gb>   root volume size in GB for an ad-hoc box
  --spot        request spot capacity for an ad-hoc box

Self-termination: a box powers off and terminates when it has been idle past
its idleMinutes (default 60) or up past its maxHours (default 24). A box counts
as busy while an ssh session is open, the 1-minute load average is at least
1.0, or its busyCommand exits 0.

Warden: terminates fleet boxes, newest first, while fleet boxes total more than
128 vCPU, and any fleet box up past fleet-max-hours (default 24).

USAGE
  printf 'Classes (from %s):\n' "$flake"
  jq -r 'to_entries[] | "  \(.key)  \(.value.instanceType)  disk \(.value.diskGb) GB  spot \(if .value.spot then "yes" else "no" end)  idle \(.value.idleMinutes) min  max \(.value.maxHours) h"' <<<"$classes"
}

case "${1:-help}" in
  help) cmd_help ;;
  ls) cmd_ls ;;
  down) cmd_down "${@:2}" ;;
  up) die "up is not implemented yet" ;;
  *) die "unknown command: $1 (see: ec2 help)" ;;
esac
