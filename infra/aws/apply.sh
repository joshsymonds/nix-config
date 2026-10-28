#!/usr/bin/env bash
# Release helper for the ec2 fleet: ensure the OpenTofu state bucket, apply
# infra/aws with admin credentials, then seal the launcher key with age.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: EC2_FLEET_ADMIN_ENV=<file> EC2_FLEET_TOFU_PASSPHRASE_FILE=<file> apply.sh [tofu apply args...]
  EC2_FLEET_ADMIN_ENV             readable env file with admin AWS credentials
  EC2_FLEET_TOFU_PASSPHRASE_FILE  readable file holding the tofu state passphrase
EOF
  exit 2
}

if [[ ! -f ${EC2_FLEET_ADMIN_ENV:-} || ! -r ${EC2_FLEET_ADMIN_ENV:-} ]]; then
  usage
fi
if [[ ! -f ${EC2_FLEET_TOFU_PASSPHRASE_FILE:-} || ! -r ${EC2_FLEET_TOFU_PASSPHRASE_FILE:-} ]]; then
  usage
fi

repo=$(cd "$(dirname "$0")/../.." && pwd)
if [[ ${EC2_FLEET_PINNED_TOOLS:-} != 1 ]]; then
  exec env EC2_FLEET_PINNED_TOOLS=1 nix shell --inputs-from "$repo" nixpkgs#opentofu nixpkgs#awscli2 nixpkgs#age --command bash --noprofile --norc "$0" "$@"
fi

set -a
eval "$(<"$EC2_FLEET_ADMIN_ENV")"
set +a
export AWS_REGION=us-west-2
TF_VAR_state_passphrase=$(<"$EC2_FLEET_TOFU_PASSPHRASE_FILE")
export TF_VAR_state_passphrase

bucket=joshsymonds-tofu-state
tofu_dir="$repo/infra/aws"

if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
  aws s3api create-bucket --bucket "$bucket" --region us-west-2 \
    --create-bucket-configuration LocationConstraint=us-west-2 >/dev/null
fi
aws s3api put-bucket-versioning --bucket "$bucket" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-lifecycle-configuration --bucket "$bucket" --lifecycle-configuration '{"Rules":[{"ID":"expire-tflock","Status":"Enabled","Filter":{"Prefix":"ec2-fleet/terraform.tfstate.tflock"},"Expiration":{"Days":1}},{"ID":"expire-noncurrent-versions","Status":"Enabled","Filter":{},"NoncurrentVersionExpiration":{"NoncurrentDays":90}}]}'

tofu -chdir="$tofu_dir" init -input=false
tofu -chdir="$tofu_dir" apply "$@"

recipients=$(nix eval --raw -f "$repo/secrets/keys.nix" joshsymonds --apply 'ks: builtins.concatStringsSep "\n" ks')
mapfile -t recipient_keys <<<"$recipients"
recipient_args=()
for key in "${recipient_keys[@]}"; do
  recipient_args+=(-r "$key")
done

access_key_id=$(tofu -chdir="$tofu_dir" output -raw launcher_access_key_id)
secret_access_key=$(tofu -chdir="$tofu_dir" output -raw launcher_secret_access_key)

target="$repo/secrets/user/ec2-fleet-aws.age"
tmp=$(mktemp "$repo/secrets/user/.ec2-fleet-aws.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$access_key_id" "$secret_access_key" \
  | age --encrypt "${recipient_args[@]}" --output "$tmp"
mv -f "$tmp" "$target"
