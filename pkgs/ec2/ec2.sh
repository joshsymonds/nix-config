# ec2: launch, list, and terminate fleet boxes in us-west-2.
# AWS credentials come only from $EC2_FLEET_AWS_ENV_FILE and the Tailscale OAuth
# client only from $EC2_FLEET_TS_ENV_FILE. Neither is printed or placed on a
# command line.

region=us-west-2
flake=${EC2_FLEET_FLAKE:-$HOME/nix-config}

# launched is the instance cmd_up started and has not finished deploying;
# userdata is the temp file holding the auth key until run-instances reads it.
launched=""
userdata=""
# base_ami is the AMI cmd_up launches from; ensure_base_ami sets it.
base_ami=""

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

# load_ts_env: reads the Tailscale OAuth client into ts_client_id and
# ts_client_secret.
load_ts_env() {
  local key value id="" secret=""
  [ -n "${EC2_FLEET_TS_ENV_FILE:-}" ] || die "EC2_FLEET_TS_ENV_FILE is not set"
  [ -r "$EC2_FLEET_TS_ENV_FILE" ] || die "cannot read $EC2_FLEET_TS_ENV_FILE"
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      TS_API_CLIENT_ID) id=$value ;;
      TS_API_CLIENT_SECRET) secret=$value ;;
    esac
  done <"$EC2_FLEET_TS_ENV_FILE"
  if [ -z "$id" ] || [ -z "$secret" ]; then
    die "$EC2_FLEET_TS_ENV_FILE lacks TS_API_CLIENT_ID or TS_API_CLIENT_SECRET"
  fi
  ts_client_id=$id
  ts_client_secret=$secret
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

# on_exit: when the launcher exits nonzero after run-instances, terminates the
# launched instance and removes the auth-key temp file.
on_exit() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -n "$launched" ]; then
    echo "ec2: launch failed; terminating $launched" >&2
    if ! aws ec2 terminate-instances --instance-ids "$launched" >/dev/null; then
      echo "ec2: could not terminate $launched; terminate it by hand" >&2
    fi
  fi
  if [ -n "$userdata" ]; then
    rm -f -- "$userdata"
  fi
}

# build_base_image <toplevel basename>: builds the raw base image, uploads it as
# a fleet=ec2-base snapshot, registers an AMI tagged with the toplevel, waits for
# it, and prunes all but the newest two base AMIs and their snapshots. Sets
# base_ami to the new AMI.
build_base_image() {
  local tl=$1 image_out image_file snap stamp reg described prune_rows
  local -a fields
  local old_snap
  image_out=$(nix build --no-link --print-out-paths "$flake#ec2-base-image") ||
    die "nix build failed for ec2-base-image"
  [ -n "$image_out" ] || die "nix build printed no output for ec2-base-image"
  image_file=$(jq -r '.file // empty' "$image_out/nix-support/image-info.json") ||
    die "cannot read the image-info of $image_out"
  [ -f "$image_file" ] || die "image-info of $image_out names no readable file"

  snap=$(coldsnap --region "$region" upload --wait --no-progress \
    --tag Key=fleet,Value=ec2-base "$image_file") || die "coldsnap upload of $image_file failed"
  [[ $snap =~ ^snap-[0-9a-f]+$ ]] || die "coldsnap printed no snapshot id"

  stamp=$(date -u +%Y%m%d%H%M%S) || die "cannot read the clock"
  if ! reg=$(aws ec2 register-image --output text --query ImageId \
    --name "ec2-base-$tl-$stamp" --architecture x86_64 --virtualization-type hvm \
    --root-device-name /dev/xvda --ena-support --boot-mode legacy-bios \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$snap,VolumeType=gp3,DeleteOnTermination=true}" \
    --tag-specifications "ResourceType=image,Tags=[{Key=fleet,Value=ec2-base},{Key=fleet-toplevel,Value=$tl}]"); then
    echo "ec2: register-image failed; deleting the unused snapshot $snap" >&2
    aws ec2 delete-snapshot --snapshot-id "$snap" >/dev/null ||
      die "could not delete unused snapshot $snap; delete it by hand"
    die "register-image failed"
  fi
  [[ $reg == ami-* ]] || die "register-image printed no AMI id"

  if ! aws ec2 wait image-available --image-ids "$reg"; then
    echo "ec2: $reg did not become available; deregistering it and deleting its snapshot $snap" >&2
    aws ec2 deregister-image --image-id "$reg" >/dev/null ||
      die "could not deregister $reg; deregister it and delete snapshot $snap by hand"
    aws ec2 delete-snapshot --snapshot-id "$snap" >/dev/null ||
      die "could not delete snapshot $snap of $reg; delete it by hand"
    die "$reg did not become available"
  fi

  described=$(aws ec2 describe-images --owners self --output json \
    --filters 'Name=tag:fleet,Values=ec2-base') || die "describe-images failed before pruning"
  prune_rows=$(jq -r '
    .Images | sort_by(.CreationDate) | reverse | .[2:][]
    | [.ImageId] + [.BlockDeviceMappings[]?.Ebs.SnapshotId // empty]
    | @tsv' <<<"$described") || die "cannot read the base AMIs to prune"
  if [ -n "$prune_rows" ]; then
    while IFS=$'\t' read -r -a fields; do
      aws ec2 deregister-image --image-id "${fields[0]}" >/dev/null ||
        die "could not deregister ${fields[0]}"
      for old_snap in "${fields[@]:1}"; do
        aws ec2 delete-snapshot --snapshot-id "$old_snap" >/dev/null ||
          die "could not delete snapshot $old_snap of ${fields[0]}"
      done
    done <<<"$prune_rows"
  fi
  base_ami=$reg
}

# ensure_base_ami <toplevel basename>: sets base_ami to the newest available
# fleet=ec2-base AMI when its fleet-toplevel tag names the toplevel. Otherwise it
# builds one.
ensure_base_ami() {
  local want=$1 images row newest_ami newest_tl
  images=$(aws ec2 describe-images --owners self --output json \
    --filters 'Name=tag:fleet,Values=ec2-base') || die "describe-images failed"
  row=$(jq -r '
    def tag($k): [.Tags[]? | select(.Key == $k) | .Value][0] // "";
    (.Images | map(select(.State == "available")) | sort_by(.CreationDate) | last // {})
    | [(.ImageId // ""), tag("fleet-toplevel")]
    | @tsv' <<<"$images") || die "cannot read the base AMIs"
  IFS=$'\t' read -r newest_ami newest_tl <<<"$row"
  if [ -n "$newest_ami" ] && [ "$newest_tl" = "$want" ]; then
    base_ami=$newest_ami
    return 0
  fi
  build_base_image "$want"
}

# cmd_up <class> | --type <t> --disk <gb> [--spot]: launches a box, waits for
# ssh on the tailnet, and for a class deploys its toplevel.
cmd_up() {
  local class="" type="" disk="" spot=no timeout
  local classes row itype disk_gb spot_req max_hours fleet_class prefix
  local known_dir deadline suffix name sgs sg body token key id toplevel base_path
  local -a ssh_opts=() market=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --type)
        [ $# -ge 2 ] || die "--type needs a value"
        type=$2
        shift 2
        ;;
      --disk)
        [ $# -ge 2 ] || die "--disk needs a value"
        disk=$2
        shift 2
        ;;
      --spot)
        spot=yes
        shift
        ;;
      --*) die "unknown flag: $1 (see: ec2 help)" ;;
      *)
        [ -z "$class" ] || die "usage: ec2 up <class> | ec2 up --type <t> --disk <gb> [--spot]"
        class=$1
        shift
        ;;
    esac
  done

  if [ -n "$class" ]; then
    if [ -n "$type$disk" ] || [ "$spot" = yes ]; then
      die "a class takes no --type, --disk or --spot"
    fi
  else
    if [ -z "$type" ] || [ -z "$disk" ]; then
      die "usage: ec2 up --type <t> --disk <gb> [--spot]"
    fi
    [[ $disk =~ ^[1-9][0-9]*$ ]] || die "--disk must be a positive integer"
  fi
  timeout=${EC2_FLEET_READY_TIMEOUT:-600}
  [[ $timeout =~ ^[0-9]+$ ]] || die "EC2_FLEET_READY_TIMEOUT must be whole seconds"

  if [ -n "$class" ]; then
    classes=$(nix eval --json "$flake#ec2Classes") || die "cannot evaluate ec2Classes in $flake"
    row=$(jq -r --arg c "$class" '
      if has($c) then .[$c] | [.instanceType, .diskGb, (if .spot then "yes" else "no" end), .maxHours] | @tsv
      else empty end' <<<"$classes") || die "cannot read the class data"
    [ -n "$row" ] || die "unknown class: $class (see: ec2 help)"
    IFS=$'\t' read -r itype disk_gb spot_req max_hours <<<"$row"
    fleet_class=$class
    prefix=$class
  else
    itype=$type
    disk_gb=$disk
    spot_req=$spot
    max_hours=24
    fleet_class=adhoc
    prefix=ec2
  fi

  load_aws_env
  load_ts_env
  known_dir=${XDG_STATE_HOME:-$HOME/.local/state}/ec2-fleet
  mkdir -p "$known_dir" || die "cannot create $known_dir"
  ssh_opts=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_dir/known_hosts")
  export NIX_SSHOPTS="${ssh_opts[*]}"

  if [ -n "$class" ]; then
    toplevel=$(nix build --no-link --print-out-paths "$flake#nixosConfigurations.ec2-$class.config.system.build.toplevel") ||
      die "nix build failed for ec2-$class"
    [ -n "$toplevel" ] || die "nix build printed no toplevel for ec2-$class"
  fi

  base_path=$(nix build --no-link --print-out-paths "$flake#nixosConfigurations.ec2-base.config.system.build.toplevel") ||
    die "nix build failed for ec2-base"
  [ -n "$base_path" ] || die "nix build printed no toplevel for ec2-base"

  suffix=$(shuf -r -n 3 -e {a..z} {0..9} | tr -d '\n') || die "cannot pick a random name"
  name="$prefix-$suffix"

  ensure_base_ami "${base_path##*/}"

  sgs=$(aws ec2 describe-security-groups --output json \
    --filters 'Name=tag:fleet,Values=ec2-sg') || die "describe-security-groups failed"
  sg=$(jq -r '.SecurityGroups[0].GroupId // empty' <<<"$sgs") || die "cannot read the security groups"
  [ -n "$sg" ] || die "no ec2-sg security group in $region"

  if [ "$spot_req" = yes ]; then
    market=(--instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}')
  fi

  body='{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":["tag:ec2"]}}},"expirySeconds":600}'
  token=$(printf 'data-urlencode = "client_id=%s"\ndata-urlencode = "client_secret=%s"\n' \
    "$ts_client_id" "$ts_client_secret" |
    curl --config - -fsS https://api.tailscale.com/api/v2/oauth/token | jq -r '.access_token // empty') ||
    die "Tailscale OAuth token request failed"
  [ -n "$token" ] || die "Tailscale returned no access token"
  key=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - -fsS -H 'Content-Type: application/json' -d "$body" \
      https://api.tailscale.com/api/v2/tailnet/-/keys | jq -r '.key // empty') ||
    die "Tailscale auth key request failed"
  [ -n "$key" ] || die "Tailscale returned no auth key"

  userdata=$(mktemp) || die "cannot create a temp file"
  printf 'EC2_FLEET_NAME=%s\nEC2_FLEET_TS_AUTHKEY=%s\n' "$name" "$key" >"$userdata" ||
    die "cannot write the user-data file"

  id=$(aws ec2 run-instances --output text --query 'Instances[0].InstanceId' \
    --image-id "$base_ami" --instance-type "$itype" --count 1 \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$disk_gb,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "DeviceIndex=0,AssociatePublicIpAddress=true,Groups=$sg" \
    --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled' \
    --instance-initiated-shutdown-behavior terminate \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=fleet,Value=ec2},{Key=fleet-class,Value=$fleet_class},{Key=fleet-max-hours,Value=$max_hours}]" \
      "ResourceType=volume,Tags=[{Key=fleet,Value=ec2},{Key=Name,Value=$name}]" \
    --user-data "file://$userdata" "${market[@]}") ||
    die "run-instances failed; nothing was launched"
  [ -n "$id" ] || die "run-instances returned no instance id; check for a new fleet=ec2 box"
  launched=$id
  rm -f -- "$userdata"
  userdata=""

  aws ec2 wait instance-running --instance-ids "$id" || die "$id did not reach running"

  deadline=$(($(date +%s) + timeout))
  until ssh "${ssh_opts[@]}" "joshsymonds@$name" true 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || die "ssh to $name did not answer within ${timeout}s"
    sleep 5
  done

  if [ -n "$class" ]; then
    nix copy --no-check-sigs --substitute-on-destination --to "ssh-ng://joshsymonds@$name" "$toplevel" ||
      die "nix copy to $name failed"
    ssh "${ssh_opts[@]}" "joshsymonds@$name" sudo nix-env -p /nix/var/nix/profiles/system --set "$toplevel" ||
      die "setting the system profile on $name failed"
    ssh "${ssh_opts[@]}" "joshsymonds@$name" sudo "$toplevel/bin/switch-to-configuration" switch ||
      die "switching $name to $toplevel failed"
  fi

  launched=""
  echo "$name ready"
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

# An interrupt exits nonzero, so on_exit terminates a launched instance.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
trap on_exit EXIT

case "${1:-help}" in
  help) cmd_help ;;
  ls) cmd_ls ;;
  down) cmd_down "${@:2}" ;;
  up) cmd_up "${@:2}" ;;
  *) die "unknown command: $1 (see: ec2 help)" ;;
esac
