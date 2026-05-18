#!/usr/bin/env bats
#
# Tests for home-manager/claude-code/hooks/ntfy-notifier.sh context
# assembly. The script must be sourceable without running main (same
# main-guard idiom as scripts/templates/bootstrap.sh), exposing the
# pure helpers so the host / devspace / window logic is asserted
# without a real tmux, kitty, or ntfy server.
#
# Run via:  ./scripts/tests/run.sh

bats_require_minimum_version 1.5.0

HOOK="${BATS_TEST_DIRNAME}/../../home-manager/claude-code/hooks/ntfy-notifier.sh"

setup() {
  FIXTURE="$(mktemp -d)"
  BIN="$FIXTURE/bin"
  mkdir -p "$BIN"

  # Stub `tmux`: prints canned values for the display-message formats the
  # hook uses (#S session, #W window, #{pane_title}). TMUX_STUB_* env
  # vars let each test choose what the stub returns.
  cat >"$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-p #S"*)            echo "${TMUX_STUB_SESSION:-}"  ;;
  *"-p #W"*)            echo "${TMUX_STUB_WINDOW:-}"   ;;
  *"-p #{pane_title}"*) echo "${TMUX_STUB_PANE:-}"     ;;
  *) echo "" ;;
esac
EOF
  chmod +x "$BIN/tmux"

  # Stub `uname`: `-n` -> deterministic fallback host for resolve_host;
  # bare `uname` -> "Linux" so get_terminal_title's Darwin check is
  # deterministic. Self-contained (no /usr/bin/uname; NixOS has none).
  cat >"$BIN/uname" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-n" ]] && { echo "${UNAME_STUB:-stub-host}"; exit 0; }
echo "Linux"
EOF
  chmod +x "$BIN/uname"

  PATH="$BIN:$PATH"

  # Hermetic: this bats process inherits the developer's real
  # DEV_CONTEXT / TMUX / TERM_PROGRAM / display env, which would mask
  # what each test sets. Scrub everything the context logic reads so
  # tests assert against a known-empty baseline.
  unset DEV_CONTEXT DEV_CONTEXT_ICON TMUX_DEVSPACE TMUX \
        TERM_PROGRAM DISPLAY WAYLAND_DISPLAY KITTY_WINDOW_TITLE

  # Sourcing must NOT run main, hit the network, or write the rate-limit
  # file. The main-guard makes this safe.
  source "$HOOK"
}

teardown() { rm -rf "$FIXTURE"; }

# ---- assemble_context: pure join, no subprocesses ----

@test "assemble_context joins host, devspace, window with middle dot" {
  run assemble_context "vermissian" "☿ mercury" "savecraft.gg"
  [ "$status" -eq 0 ]
  [ "$output" = "vermissian · ☿ mercury · savecraft.gg" ]
}

@test "assemble_context drops an empty devspace without doubling separators" {
  run assemble_context "vermissian" "" "savecraft.gg"
  [ "$output" = "vermissian · savecraft.gg" ]
}

@test "assemble_context with only a host yields just the host" {
  run assemble_context "gnomon" "" ""
  [ "$output" = "gnomon" ]
}

@test "assemble_context never emits a leading or trailing separator" {
  run assemble_context "" "earth" ""
  [ "$output" = "earth" ]
}

# ---- resolve_devspace: tmux session name only, icon-prefixed ----

@test "resolve_devspace returns icon + tmux session name in a real session" {
  TMUX="/tmp/fake" TMUX_STUB_SESSION="mercury" DEV_CONTEXT_ICON="☿" \
    run resolve_devspace
  [ "$output" = "☿ mercury" ]
}

@test "resolve_devspace returns the bare session name when no icon" {
  TMUX="/tmp/fake" TMUX_STUB_SESSION="mars" run resolve_devspace
  [ "$output" = "mars" ]
}

@test "resolve_devspace ignores DEV_CONTEXT when not in a tmux session" {
  # The shell sets DEV_CONTEXT to the hostname outside a devspace;
  # that must NOT be treated as a devspace (this was the gnomon·gnomon bug).
  DEV_CONTEXT="gnomon" DEV_CONTEXT_ICON="☿" run resolve_devspace
  [ "$output" = "" ]
}

@test "resolve_devspace is empty with no tmux at all" {
  run resolve_devspace
  [ "$output" = "" ]
}

@test "resolve_devspace is empty when tmux has no session name" {
  TMUX="/tmp/fake" TMUX_STUB_SESSION="" run resolve_devspace
  [ "$output" = "" ]
}

# ---- resolve_host ----

@test "resolve_host strips the domain from HOSTNAME" {
  HOSTNAME="vermissian.lan" run resolve_host
  [ "$output" = "vermissian" ]
}

@test "resolve_host falls back to uname -n when HOSTNAME empty" {
  # bash auto-repopulates HOSTNAME in a fresh shell, so a subshell
  # can't simulate "unset"; emptying it for the call exercises the
  # same fallback branch (h="" -> uname -n stub).
  HOSTNAME="" UNAME_STUB="fallbackbox" run resolve_host
  [ "$output" = "fallbackbox" ]
}

# ---- clean_terminal_title: pure ----

@test "clean_terminal_title strips claude emoji and control chars" {
  run clean_terminal_title "$(printf '✅ working on savecraft.gg\t')"
  [ "$output" = "working on savecraft.gg" ]
}

# ---- get_terminal_title: tmux branch via stub ----

@test "get_terminal_title returns 'window - pane' under tmux" {
  TERM_PROGRAM="tmux" TMUX="/tmp/fake" \
    TMUX_STUB_WINDOW="savecraft.gg" TMUX_STUB_PANE="nvim" \
    run get_terminal_title
  [ "$output" = "savecraft.gg - nvim" ]
}

# ---- claude_title: strip "claude" + leading spinner/separators ----

@test "claude_title strips the claude window name and spinner glyph" {
  TERM_PROGRAM="tmux" TMUX="/tmp/fake" \
    TMUX_STUB_WINDOW="claude" \
    TMUX_STUB_PANE="✳ Review handoff and plan gambit brainstorming" \
    run claude_title
  [ "$output" = "Review handoff and plan gambit brainstorming" ]
}

@test "claude_title handles a braille spinner glyph too" {
  TERM_PROGRAM="tmux" TMUX="/tmp/fake" \
    TMUX_STUB_WINDOW="claude" \
    TMUX_STUB_PANE="⠂ Analyze user activity and acquisition metrics" \
    run claude_title
  [ "$output" = "Analyze user activity and acquisition metrics" ]
}

@test "claude_title leaves a claude-free title intact" {
  TERM_PROGRAM="tmux" TMUX="/tmp/fake" \
    TMUX_STUB_WINDOW="savecraft.gg" TMUX_STUB_PANE="savecraft.gg" \
    run claude_title
  [ "$output" = "savecraft.gg" ]
}

@test "claude_title is empty when the title is only 'claude'" {
  TERM_PROGRAM="tmux" TMUX="/tmp/fake" \
    TMUX_STUB_WINDOW="claude" TMUX_STUB_PANE="claude" \
    run claude_title
  [ "$output" = "" ]
}

# ---- end-to-end get_context: two segments ----

@test "get_context is 'icon session · task' inside a devspace (host omitted)" {
  HOSTNAME="vermissian.lan" \
  DEV_CONTEXT_ICON="☿" \
  TERM_PROGRAM="tmux" TMUX="/tmp/fake" \
  TMUX_STUB_SESSION="mercury" \
  TMUX_STUB_WINDOW="claude" \
  TMUX_STUB_PANE="✳ Review handoff and plan gambit brainstorming" \
    run get_context
  [ "$output" = "☿ mercury · Review handoff and plan gambit brainstorming" ]
}

@test "get_context uses the host (not DEV_CONTEXT fallback) when not in tmux" {
  cd "$FIXTURE"
  HOSTNAME="gnomon" DEV_CONTEXT="gnomon" DEV_CONTEXT_ICON="☿" run get_context
  [ "$output" = "gnomon · $(basename "$FIXTURE")" ]
}

@test "get_context falls back to cwd basename when no terminal title" {
  cd "$FIXTURE"
  HOSTNAME="gnomon" run get_context
  [ "$output" = "gnomon · $(basename "$FIXTURE")" ]
}
