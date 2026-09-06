#!/usr/bin/env bash
# AWS_PROFILE mirror hook for the Steward statusline.
#
# Wired as a PostToolUse hook on the Bash tool. After every Bash call,
# scans the executed command text for `export AWS_PROFILE=...` or
# `unset AWS_PROFILE` and mirrors the latest value (or empty string) to
# ${STEWARD_STATE_FILE:-~/.cache/steward/state.json}. Steward's EnvReader reads
# this file in preference to the process env so the chip reflects Claude's
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

state_file="${STEWARD_STATE_FILE:-$HOME/.cache/steward/state.json}"
state_dir="${state_file%/*}"

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

# Split the command on shell separators so each logical statement
# becomes one line. Then anchor the export/unset match at the start
# of that line (after whitespace) so `echo "export AWS_PROFILE=fake"`,
# `# unset AWS_PROFILE in comment`, and `grep "export AWS_PROFILE"`
# don't false-positive.
while IFS= read -r line; do
  # Properly strip leading whitespace (POSIX): sed-based, not the
  # single-space `${line## }` trick which only strips one char.
  trimmed=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//')
  case "$trimmed" in
    "export AWS_PROFILE="*)
      # `export AWS_PROFILE=VALUE` — take the value (everything after =).
      value="${trimmed#export AWS_PROFILE=}"
      # If the value has a trailing word (separator collapsed by our
      # `tr` earlier left one), trim at the first space.
      value="${value%% *}"
      # Strip surrounding quotes.
      value="${value#\"}"
      value="${value%\"}"
      value="${value#\'}"
      value="${value%\'}"
      new_value="$value"
      new_value_set="yes"
      ;;
    "unset AWS_PROFILE"|"unset AWS_PROFILE "*)
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
# rename so Steward never sees a partial file. `jq -n --arg p` produces
# valid JSON for any value including empty strings — without this, the
# unset-AWS_PROFILE case used to emit `{"aws_profile":}` (malformed).
tmp="$state_file.tmp.$$"
if [ -f "$state_file" ]; then
  jq --arg p "$new_value" '.aws_profile = $p' "$state_file" > "$tmp" 2>/dev/null \
    || jq -n --arg p "$new_value" '{aws_profile: $p}' > "$tmp"
else
  jq -n --arg p "$new_value" '{aws_profile: $p}' > "$tmp"
fi
mv "$tmp" "$state_file"
