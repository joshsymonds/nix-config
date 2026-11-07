# ec2: launch, list, and terminate fleet boxes in us-west-2 and eu-west-1.
# AWS credentials come only from $EC2_FLEET_AWS_ENV_FILE and the Tailscale OAuth
# client only from $EC2_FLEET_TS_ENV_FILE. Neither is printed or placed on a
# command line.

regions=(us-west-2 eu-west-1)
flake=${EC2_FLEET_FLAKE:-$HOME/nix-config}

# launched is the instance cmd_up started and has not finished deploying;
# launched_region is the region it runs in; userdata is the temp file holding
# the auth key until run-instances reads it; runerr is the temp file holding the
# stderr of run-instances.
launched=""
launched_region=""
userdata=""
runerr=""
# base_ami is the AMI ensure_base_ami found or built; region_ami and region_sg
# hold each region's base AMI and security group once the walk reaches it.
base_ami=""
declare -A region_ami=() region_sg=()

die() {
  echo "ec2: $*" >&2
  exit 1
}

# ec2_in <region> <ec2 subcommand and args>: runs one aws ec2 call in the region.
ec2_in() {
  local r=$1
  shift
  AWS_REGION=$r AWS_DEFAULT_REGION=$r aws ec2 "$@"
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
  export AWS_ACCESS_KEY_ID=$access AWS_SECRET_ACCESS_KEY=$secret
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

# on_demand_price <region> <type>: Linux on-demand $/hr in the region.
on_demand_price() {
  aws pricing get-products --region us-east-1 --service-code AmazonEC2 --output json \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$2" \
    "Type=TERM_MATCH,Field=regionCode,Value=$1" \
    "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
    "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
    "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
    "Type=TERM_MATCH,Field=capacitystatus,Value=Used" |
    jq -r '[.PriceList[] | fromjson | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD] | first // "n/a"'
}

# spot_price <region> <type> <az>: newest Linux spot $/hr for the type in the zone.
spot_price() {
  ec2_in "$1" describe-spot-price-history --output json --instance-types "$2" \
    --availability-zone "$3" --product-descriptions 'Linux/UNIX' |
    jq -r '.SpotPriceHistory | max_by(.Timestamp).SpotPrice // "n/a"'
}

# rank_regions <type> <region>...: prints the regions cheapest on-demand first,
# equal prices in the order given. A price that cannot be read warns once on
# stderr and prints the regions in the order given.
rank_regions() {
  local itype=$1 r p
  local -a priced=()
  shift
  [ $# -gt 1 ] || {
    printf '%s\n' "$@"
    return 0
  }
  for r in "$@"; do
    p=$(on_demand_price "$r" "$itype") || p=
    [[ $p =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
      echo "ec2: cannot rank regions by on-demand price for $itype; trying them in fixed order" >&2
      printf '%s\n' "$@"
      return 0
    }
    priced+=("$p $r")
  done
  printf '%s\n' "${priced[@]}" | sort -s -n | cut -d' ' -f2
}

# region_spot_price <type> <region>: prints the lowest current spot $/hr among the
# region's offering zones, from region_zones. Fails when any zone's price cannot
# be read.
region_spot_price() {
  local itype=$1 r=$2 zone p
  local -a zones=() prices=()
  readarray -t zones <<<"${region_zones[$r]}"
  for zone in "${zones[@]}"; do
    p=$(spot_price "$r" "$itype" "$zone") || return 1
    [[ $p =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    prices+=("$p")
  done
  printf '%s\n' "${prices[@]}" | sort -n | head -n 1
}

# rank_spot_regions <type> <region>...: prints the regions highest spot placement
# score first, from one score lookup in us-west-2. A score tie goes to the region
# with the lower spot price, read only for the tied regions; a price tie keeps the
# order given. A failed or incomplete score lookup, or an unreadable price, warns
# once on stderr and prints the regions in the order given.
rank_spot_regions() {
  local itype=$1 r s p scores
  local -a scored=() keyed=()
  local -A count=()
  shift
  [ $# -gt 1 ] || {
    printf '%s\n' "$@"
    return 0
  }
  scores=$(ec2_in us-west-2 get-spot-placement-scores --output json \
    --region-names "$@" --instance-types "$itype" --target-capacity 1) || scores=
  for r in "$@"; do
    s=$(jq -r --arg r "$r" '[.SpotPlacementScores[] | select(.Region == $r) | .Score | numbers] | first // empty' <<<"$scores") || s=
    [[ $s =~ ^[0-9]+$ ]] || {
      echo "ec2: cannot rank regions by spot placement score for $itype; trying them in fixed order" >&2
      printf '%s\n' "$@"
      return 0
    }
    scored+=("$s $r")
    count[$s]=$((${count[$s]:-0} + 1))
  done
  for entry in "${scored[@]}"; do
    s=${entry%% *}
    r=${entry#* }
    p=0
    if [ "${count[$s]}" -gt 1 ]; then
      p=$(region_spot_price "$itype" "$r") || p=
      [[ $p =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
        echo "ec2: cannot break the spot score tie for $itype by price; trying them in fixed order" >&2
        printf '%s\n' "$@"
        return 0
      }
    fi
    keyed+=("$s $p $r")
  done
  printf '%s\n' "${keyed[@]}" | sort -s -k1,1nr -k2,2n | cut -d' ' -f3
}

cmd_ls() {
  local region described rows name class itype spot launch az od sp
  load_aws_env
  printf '%-28s %-18s %-14s %-5s %-8s %-13s %s\n' NAME CLASS TYPE SPOT AGE ON-DEMAND/HR SPOT/HR
  for region in "${regions[@]}"; do
    described=$(ec2_in "$region" describe-instances --output json \
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
    if [ -z "$rows" ]; then
      continue
    fi
    while IFS=$'\t' read -r name class itype spot launch az; do
      od=$(on_demand_price "$region" "$itype") || die "pricing lookup failed for $itype in $region"
      sp=$(spot_price "$region" "$itype" "$az") || die "spot price lookup failed for $itype in $az"
      printf '%-28s %-18s %-14s %-5s %-8s %-13s %s\n' "$name" "$class" "$itype" "$spot" \
        "$(age_of "$launch")" "$od" "$sp"
    done <<<"$rows"
  done
}

cmd_down() {
  local name region described ids matches=""
  [ $# -eq 1 ] || die "usage: ec2 down <name>"
  name=$1
  load_aws_env
  # Each match is one "<region> <instance id>" line, collected across both regions.
  for region in "${regions[@]}"; do
    described=$(ec2_in "$region" describe-instances --output json \
      --filters "Name=tag:Name,Values=$name" 'Name=tag:fleet,Values=ec2' \
      'Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down')
    ids=$(jq -r --arg name "$name" --arg region "$region" '
      def tag($k): [.Tags[]? | select(.Key == $k) | .Value][0] // "";
      .Reservations[].Instances[]
      | select(.State.Name != "terminated")
      | select(tag("fleet") == "ec2" and tag("Name") == $name)
      | "\($region) \(.InstanceId)"' <<<"$described")
    if [ -n "$ids" ]; then
      matches+="$ids"$'\n'
    fi
  done
  if [ -z "$matches" ]; then
    die "no fleet box named $name"
  fi
  matches=${matches%$'\n'}
  case "$matches" in
    *$'\n'*) die "more than one fleet box named $name; refusing to terminate" ;;
  esac
  read -r region ids <<<"$matches"
  ec2_in "$region" terminate-instances --instance-ids "$ids" >/dev/null
  echo "terminating $ids ($name)"
}

# on_exit: when the launcher exits nonzero after run-instances, terminates the
# launched instance and removes the auth-key temp file.
on_exit() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -n "$launched" ]; then
    # A closed stderr must not stop the terminate.
    echo "ec2: launch failed; terminating $launched" >&2 || :
    if ! ec2_in "$launched_region" terminate-instances --instance-ids "$launched" >/dev/null; then
      echo "ec2: could not terminate $launched; terminate it by hand" >&2 || :
    fi
  fi
  if [ -n "$userdata" ]; then
    rm -f -- "$userdata"
  fi
  if [ -n "$runerr" ]; then
    rm -f -- "$runerr"
  fi
}

# build_base_image <region> <toplevel basename>: builds the raw base image, uploads
# it in the region as a fleet=ec2-base snapshot, registers an AMI tagged with the
# toplevel, waits for it, and prunes all but the newest two of the region's base
# AMIs and their snapshots. Sets base_ami to the new AMI.
build_base_image() {
  local r=$1 tl=$2 image_out image_file snap stamp reg described prune_rows
  local -a fields
  local old_snap
  image_out=$(nix build --no-link --print-out-paths "$flake#ec2-base-image") ||
    die "nix build failed for ec2-base-image"
  [ -n "$image_out" ] || die "nix build printed no output for ec2-base-image"
  image_file=$(jq -r '.file // empty' "$image_out/nix-support/image-info.json") ||
    die "cannot read the image-info of $image_out"
  [ -f "$image_file" ] || die "image-info of $image_out names no readable file"

  snap=$(coldsnap --region "$r" upload --wait --no-progress \
    --tag Key=fleet,Value=ec2-base "$image_file") || die "coldsnap upload of $image_file failed"
  [[ $snap =~ ^snap-[0-9a-f]+$ ]] || die "coldsnap printed no snapshot id"

  stamp=$(date -u +%Y%m%d%H%M%S) || die "cannot read the clock"
  if ! reg=$(ec2_in "$r" register-image --output text --query ImageId \
    --name "ec2-base-$tl-$stamp" --architecture x86_64 --virtualization-type hvm \
    --root-device-name /dev/xvda --ena-support --boot-mode legacy-bios \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$snap,VolumeType=gp3,DeleteOnTermination=true}" \
    --tag-specifications "ResourceType=image,Tags=[{Key=fleet,Value=ec2-base},{Key=fleet-toplevel,Value=$tl}]"); then
    echo "ec2: register-image failed; deleting the unused snapshot $snap" >&2
    ec2_in "$r" delete-snapshot --snapshot-id "$snap" >/dev/null ||
      die "could not delete unused snapshot $snap; delete it by hand"
    die "register-image failed"
  fi
  [[ $reg == ami-* ]] || die "register-image printed no AMI id"

  if ! ec2_in "$r" wait image-available --image-ids "$reg"; then
    echo "ec2: $reg did not become available; deregistering it and deleting its snapshot $snap" >&2
    ec2_in "$r" deregister-image --image-id "$reg" >/dev/null ||
      die "could not deregister $reg; deregister it and delete snapshot $snap by hand"
    ec2_in "$r" delete-snapshot --snapshot-id "$snap" >/dev/null ||
      die "could not delete snapshot $snap of $reg; delete it by hand"
    die "$reg did not become available"
  fi

  described=$(ec2_in "$r" describe-images --owners self --output json \
    --filters 'Name=tag:fleet,Values=ec2-base') || die "describe-images failed before pruning"
  prune_rows=$(jq -r '
    .Images | sort_by(.CreationDate) | reverse | .[2:][]
    | [.ImageId] + [.BlockDeviceMappings[]?.Ebs.SnapshotId // empty]
    | @tsv' <<<"$described") || die "cannot read the base AMIs to prune"
  if [ -n "$prune_rows" ]; then
    while IFS=$'\t' read -r -a fields; do
      ec2_in "$r" deregister-image --image-id "${fields[0]}" >/dev/null ||
        die "could not deregister ${fields[0]}"
      for old_snap in "${fields[@]:1}"; do
        ec2_in "$r" delete-snapshot --snapshot-id "$old_snap" >/dev/null ||
          die "could not delete snapshot $old_snap of ${fields[0]}"
      done
    done <<<"$prune_rows"
  fi
  base_ami=$reg
}

# ensure_base_ami <region> <toplevel basename>: sets base_ami to the newest
# available fleet=ec2-base AMI in the region when its fleet-toplevel tag names the
# toplevel. Otherwise it builds one there.
ensure_base_ami() {
  local r=$1 want=$2 images row newest_ami newest_tl
  images=$(ec2_in "$r" describe-images --owners self --output json \
    --filters 'Name=tag:fleet,Values=ec2-base') || die "describe-images failed in $r"
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
  build_base_image "$r" "$want"
}

# resolve_region <region> <toplevel basename>: finds or builds the region's base
# AMI and finds its ec2-sg security group, into region_ami and region_sg.
resolve_region() {
  local r=$1 sgs sg
  ensure_base_ami "$r" "$2"
  region_ami[$r]=$base_ami
  sgs=$(ec2_in "$r" describe-security-groups --output json \
    --filters 'Name=tag:fleet,Values=ec2-sg') || die "describe-security-groups failed in $r"
  sg=$(jq -r '.SecurityGroups[0].GroupId // empty' <<<"$sgs") || die "cannot read the security groups in $r"
  [ -n "$sg" ] || die "no ec2-sg security group in $r"
  region_sg[$r]=$sg
}

# create_userdata <name>: asks Tailscale for a tagged, single-use auth key and
# writes the user-data file that carries it, setting userdata to that file.
create_userdata() {
  local name=$1 body token key
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
}

# cmd_up <class> [--override-input <input> <flake-url>]... | --type <t> --disk <gb>
# [--spot]: launches a box, waits for ssh on the tailnet, and for a class deploys
# its toplevel built with each input override.
cmd_up() {
  local class="" type="" disk="" spot=no timeout
  local classes row itype disk_gb spot_req max_hours reboot_req fleet_class prefix
  local known_dir deadline suffix name toplevel base_path id=""
  local boot_before boot_after
  local zone_list zone r kind aregion attempt reply market_line
  local -a ssh_opts=() reboot_opts=() zones=() attempts=() spot_attempts=() od_attempts=()
  local -a place=() market=() overrides=()
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
      --override-input)
        [ $# -ge 3 ] && [ -n "$2" ] && [ -n "$3" ] ||
          die "--override-input needs an input and a flake URL"
        overrides+=(--override-input "$2" "$3")
        shift 3
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
    if [ ${#overrides[@]} -gt 0 ]; then
      die "--override-input needs a class"
    fi
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
      if has($c) then .[$c] | [.instanceType, .diskGb, (if .spot then "yes" else "no" end), .maxHours, (if .reboot then "yes" else "no" end)] | @tsv
      else empty end' <<<"$classes") || die "cannot read the class data"
    [ -n "$row" ] || die "unknown class: $class (see: ec2 help)"
    IFS=$'\t' read -r itype disk_gb spot_req max_hours reboot_req <<<"$row"
    fleet_class=$class
    prefix=$class
  else
    itype=$type
    disk_gb=$disk
    spot_req=$spot
    reboot_req=no
    max_hours=24
    fleet_class=adhoc
    prefix=ec2
  fi

  load_aws_env
  load_ts_env
  known_dir=${XDG_STATE_HOME:-$HOME/.local/state}/ec2-fleet
  mkdir -p "$known_dir" || die "cannot create $known_dir"
  ssh_opts=(-o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_dir/known_hosts")
  export NIX_SSHOPTS="${ssh_opts[*]}"

  if [ -n "$class" ]; then
    toplevel=$(nix build --no-link --print-out-paths "${overrides[@]}" "$flake#nixosConfigurations.ec2-$class.config.system.build.toplevel") ||
      die "nix build failed for ec2-$class"
    [ -n "$toplevel" ] || die "nix build printed no toplevel for ec2-$class"
  fi

  base_path=$(nix build --no-link --print-out-paths "$flake#nixosConfigurations.ec2-base.config.system.build.toplevel") ||
    die "nix build failed for ec2-base"
  [ -n "$base_path" ] || die "nix build printed no toplevel for ec2-base"

  # The walk runs over the regions in order. A spot launch tries the regions
  # offering the type in spot placement score order, each one's zones in sorted
  # order, as spot. Then, for every launch, the regions offering the type are
  # ranked by on-demand price, cheapest first, and each one's zones as on-demand,
  # placed, then its one on-demand attempt with no placement. A region offering
  # no zone for the type gets no attempt.
  local ranked spot_ranked
  local -a offering=() od_regions=() spot_regions=()
  local -A region_zones=() quota_skip=()
  for r in "${regions[@]}"; do
    zone_list=$(ec2_in "$r" describe-instance-type-offerings --output json --location-type availability-zone \
      --filters "Name=instance-type,Values=$itype" |
      jq -r '[.InstanceTypeOfferings[].Location] | sort | .[]') ||
      die "cannot list the zones offering $itype in $r"
    [ -n "$zone_list" ] || continue
    offering+=("$r")
    region_zones[$r]=$zone_list
  done
  [ ${#offering[@]} -gt 0 ] || die "no region offers $itype"
  if [ "$spot_req" = yes ]; then
    spot_ranked=$(rank_spot_regions "$itype" "${offering[@]}") || die "cannot order the regions offering $itype for spot"
    readarray -t spot_regions <<<"$spot_ranked"
    for r in "${spot_regions[@]}"; do
      readarray -t zones <<<"${region_zones[$r]}"
      for zone in "${zones[@]}"; do
        spot_attempts+=("spot $r $zone")
      done
    done
  fi
  ranked=$(rank_regions "$itype" "${offering[@]}") || die "cannot order the regions offering $itype"
  readarray -t od_regions <<<"$ranked"
  for r in "${od_regions[@]}"; do
    readarray -t zones <<<"${region_zones[$r]}"
    for zone in "${zones[@]}"; do
      od_attempts+=("on-demand $r $zone")
    done
    od_attempts+=("on-demand $r")
  done
  attempts=("${spot_attempts[@]}" "${od_attempts[@]}")

  runerr=$(mktemp) || die "cannot create a temp file"
  for attempt in "${attempts[@]}"; do
    read -r kind aregion zone <<<"$attempt"
    # A market that hit its quota in a region is skipped there for the rest of
    # the walk, placed and unplaced alike.
    if [ -n "${quota_skip[$kind:$aregion]:-}" ]; then
      continue
    fi
    # The region's base AMI and security group are found, or built, the first time
    # the walk reaches the region. A launch gets its name, Tailscale key and
    # user-data when it has none: at the first region, and again after a box fails
    # its running wait.
    if [ -z "${region_sg[$aregion]:-}" ]; then
      resolve_region "$aregion" "${base_path##*/}"
    fi
    if [ -z "$userdata" ]; then
      suffix=$(shuf -r -n 3 -e {a..z} {0..9} | tr -d '\n') || die "cannot pick a random name"
      name="$prefix-$suffix"
      create_userdata "$name"
    fi
    place=()
    market=()
    if [ -n "$zone" ]; then
      place=(--placement "AvailabilityZone=$zone")
    fi
    if [ "$kind" = spot ]; then
      market=(--instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}')
      market_line="market spot $zone"
    else
      market_line="market on-demand"
    fi
    if reply=$(ec2_in "$aregion" run-instances --output text --query 'Instances[0].InstanceId' \
      --image-id "${region_ami[$aregion]}" --instance-type "$itype" --count 1 \
      --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$disk_gb,VolumeType=gp3,DeleteOnTermination=true}" \
      --network-interfaces "DeviceIndex=0,AssociatePublicIpAddress=true,Groups=${region_sg[$aregion]}" \
      --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled' \
      --instance-initiated-shutdown-behavior terminate \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=fleet,Value=ec2},{Key=fleet-class,Value=$fleet_class},{Key=fleet-max-hours,Value=$max_hours}]" \
        "ResourceType=volume,Tags=[{Key=fleet,Value=ec2},{Key=Name,Value=$name}]" \
      --user-data "file://$userdata" "${place[@]}" "${market[@]}" 2>"$runerr"); then
      id=$reply
      launched=$id
      launched_region=$aregion
      cat -- "$runerr" >&2
      [ -n "$id" ] || die "run-instances returned no instance id; check for a new fleet=ec2 box"
      if ec2_in "$aregion" wait instance-running --instance-ids "$id"; then
        break
      fi
      # A box that does not reach running is terminated in its region and forgotten
      # as the launched box, so on_exit does not terminate it again. The walk goes on
      # with a fresh name, key and user-data.
      launched=""
      launched_region=""
      ec2_in "$aregion" terminate-instances --instance-ids "$id" >/dev/null ||
        die "could not terminate $id; terminate it by hand"
      echo "ec2: $id did not reach running in $aregion; terminated it" >&2
      id=""
      rm -f -- "$userdata"
      userdata=""
      continue
    fi
    if grep -q InsufficientInstanceCapacity "$runerr"; then
      echo "ec2: no $kind capacity for $itype in ${zone:-$aregion}" >&2
      continue
    fi
    # A RequestLimitExceeded that names an availability zone is throttling of
    # that zone; one that names none is account-level and stops the launch.
    if [ -n "$zone" ] && grep -E -q 'RequestLimitExceeded.*availability zone [a-z0-9-]+' "$runerr"; then
      echo "ec2: $kind launch throttled in $zone" >&2
      continue
    fi
    # A spot or on-demand quota refusal names the market's quota; the market's
    # attempts in this region are skipped, and the walk goes on.
    if grep -q -E 'MaxSpotInstanceCountExceeded|VcpuLimitExceeded' "$runerr"; then
      echo "ec2: $kind quota reached for $itype in $aregion; skipping its $kind attempts there" >&2
      quota_skip[$kind:$aregion]=yes
      continue
    fi
    cat -- "$runerr" >&2
    die "run-instances failed; nothing was launched"
  done
  rm -f -- "$runerr"
  runerr=""
  [ -n "$id" ] || die "no region could launch $itype; nothing was launched"
  rm -f -- "$userdata"
  userdata=""
  echo "$market_line"

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
    if [ "$reboot_req" = yes ]; then
      # Every call on the reboot path is bounded: a connection that never
      # answers or goes silent ends the call instead of hanging the launch.
      reboot_opts=("${ssh_opts[@]}" -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
      boot_before=$(ssh "${reboot_opts[@]}" "joshsymonds@$name" cat /proc/sys/kernel/random/boot_id) ||
        die "reading the boot id of $name failed"
      [ -n "$boot_before" ] || die "$name reported no boot id before the reboot"
      ssh "${reboot_opts[@]}" "joshsymonds@$name" sudo "$toplevel/bin/switch-to-configuration" boot ||
        die "switching $name to $toplevel for boot failed"
      deadline=$(($(date +%s) + timeout))
      # The exit status of the reboot request is not checked: the connection
      # drops as the box goes down. The new boot id is the evidence.
      ssh "${reboot_opts[@]}" "joshsymonds@$name" sudo systemctl reboot || :
      until boot_after=$(ssh "${reboot_opts[@]}" "joshsymonds@$name" cat /proc/sys/kernel/random/boot_id 2>/dev/null) &&
        [ -n "$boot_after" ] && [ "$boot_after" != "$boot_before" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || die "$name did not report a new boot id within ${timeout}s"
        sleep 5
      done
    else
      ssh "${ssh_opts[@]}" "joshsymonds@$name" sudo "$toplevel/bin/switch-to-configuration" switch ||
        die "switching $name to $toplevel failed"
    fi
  fi

  launched=""
  launched_region=""
  echo "$name ready"
}

cmd_help() {
  local classes
  classes=$(nix eval --json "$flake#ec2Classes")
  cat <<'USAGE'
ec2 - launch, list, and terminate fleet boxes in us-west-2 and eu-west-1

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
  --override-input <input> <flake-url>
                build a class box's toplevel with a flake input overridden;
                repeat the flag for each input (classes only)

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
