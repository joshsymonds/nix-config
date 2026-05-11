#!/usr/bin/env bash
# AWS_PROFILE mirror hook for cc-tools statusline.
#
# Wired as a PostToolUse hook on the Bash tool. After every Bash call,
# scans the executed command text for `export AWS_PROFILE=...` or
# `unset AWS_PROFILE` and mirrors the latest value (or empty string) to
# ~/.cache/cc-tools/state.json. cc-tools' EnvReader reads this file
# in preference to the process env so the chip reflects Claude's
# declared profile even though the Bash subshell's env doesn't survive.
#
# DISPLAY-ONLY caveat: the statusline reflects Claude's *intent*. The
# actual Bash subshell env is unchanged across Claude's commands — to
# use a non-launch profile, Claude must prefix each aws call (e.g.
# `AWS_PROFILE=foo aws ...`) or re-export inside the same Bash call.
#
# Input on stdin: Claude Code hook JSON.
# Output: silent on success, errors to stderr.

set -u

state_dir="$HOME/.cache/cc-tools"
state_file="$state_dir/state.json"

# Read the full hook payload; bail quietly on read errors.
payload="$(cat)" || exit 0

# Extract tool_input.command using jq. Fall back to nothing if jq is
# missing or the field is absent.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
if [ -z "$cmd" ]; then
  exit 0
fi

# Look for the LAST `export AWS_PROFILE=...` or `unset AWS_PROFILE`
# in the command text. Handles both `export AWS_PROFILE=value` and
# `unset AWS_PROFILE`. Values may be quoted with single or double
# quotes; we strip them.
new_value=""
new_value_set="no"

while IFS= read -r line; do
  # Trim leading whitespace and an optional leading `&&`/`;`/`|`.
  trimmed="${line## }"
  case "$trimmed" in
    *"export AWS_PROFILE="*)
      # Take everything after the last `export AWS_PROFILE=`.
      value="${trimmed##*export AWS_PROFILE=}"
      # Strip any trailing shell separators (`&&`, `;`, `|`, etc.) by
      # taking only the first word.
      value="${value%% *}"
      value="${value%%;*}"
      value="${value%%&*}"
      value="${value%%|*}"
      # Strip surrounding quotes.
      value="${value#\"}"
      value="${value%\"}"
      value="${value#\'}"
      value="${value%\'}"
      new_value="$value"
      new_value_set="yes"
      ;;
    *"unset AWS_PROFILE"*)
      new_value=""
      new_value_set="yes"
      ;;
  esac
done <<EOF
$(printf '%s\n' "$cmd" | tr ';&|' '\n')
EOF

# Nothing to mirror — leave the file as-is.
if [ "$new_value_set" = "no" ]; then
  exit 0
fi

mkdir -p "$state_dir" 2>/dev/null || exit 0

# Read existing state if any; merge the aws_profile field. Atomic
# rename so cc-tools never sees a partial file.
tmp="$state_file.tmp.$$"
if [ -f "$state_file" ] && command -v jq >/dev/null 2>&1; then
  jq --arg p "$new_value" '.aws_profile = $p' "$state_file" 2>/dev/null > "$tmp" || \
    printf '{"aws_profile":%s}\n' "$(printf '%s' "$new_value" | jq -R .)" > "$tmp"
else
  printf '{"aws_profile":%s}\n' "$(printf '%s' "$new_value" | jq -R .)" > "$tmp"
fi
mv "$tmp" "$state_file"
