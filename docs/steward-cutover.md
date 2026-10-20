# Steward consumer cutover

This configuration preserves the deployed user configuration from deployed user commit
2b1a0eeb85461bccbc42808c94a666eef07aa127 (published from
`worktree-astra-xhigh-steelman`), which is newer than local main
`8d8c473`. It consumes the intended Steward source
`joshsymonds/steward` at `f26cdde8f8ce7dc079896bcae7a8747151158778` for
Vermissian; neither pin is a release claim.

## Shared ownership

`home-manager/steward/default.nix` is the sole common owner of the default
Steward package, the `steward-notifyd` user service, the ntfy age secrets, and
the canonical `STEWARD_*` environment. Shell sessions receive only secret-file
paths. The service expands agenix's runtime path in its shell, reads the
secrets at process start, and exports the effective Home Manager helper/model
values; no secret value enters the Nix store.

The desktop, headless, and minimal profiles already select Home Manager's
`sd-switch`. During generation activation, it receives both the old and new
unit directories and stops removed owned units, so no additional best-effort
`systemctl` activation is used to retire `cc-tools-notifyd`. This does not
delete historical state.

The paired `steward-pi-runtime` output supplies both Pi's extension root and
its physical `node_modules` graph. Pi runs from the same default Steward
package and loads the owned subagents wrapper before the owned extension. The
tasks, goal, and LSP packages all link `typebox` from that paired graph rather
than from a second Pi installation. LSP and all four server mappings are part
of the merged deployed-user-preserving configuration.

## Native consumers

- Claude keeps usage-summary refresh as its first root `Stop` command and then
  runs `steward notify --harness claude-code` with its 90-second timeout.
  `permission_prompt`, `agent_needs_input`, `elicitation_dialog`, and
  `elicitation_url_dialog` use the explicit-input notification hook.
  `SessionEnd` invokes Steward for cleanup, and no `SubagentStop` notification
  is present.
- Pi gets root/child classification, settled notification, labels, footer, and
  quota integration from Steward's packaged extension. No consumer-side adapter
  or second pi-subagents package remains. Its `openai-codex` provider, model
  helper, and quota behavior are unchanged.
- Steward has no Codex CLI hook, trust, notify, or installer integration. Codex
  itself remains installed, with its native approval policy and approval UI.
  Its ordinary atomic baseline-wins config merge preserves unrelated mutable
  hooks, projects, state, and custom fields.

## Verification boundary

Run the lightweight gate against the merged deployed-user-preserving configuration. It
verifies the consumer obligations unconditionally, including Pi's tasks, goal,
LSP, browser/web/process tools and context, plus the Claude Opus 5.5 and Pi
Astra defaults.
Use the published package selected by the pinned Steward input:

```sh
steward_package="$(nix build --no-link --print-out-paths --impure --expr 'let f = builtins.getFlake (toString ./.); in f.inputs.steward.packages.${builtins.currentSystem}.default')"
STEWARD_TEST_BIN="$steward_package/bin/steward" node --test home-manager/steward/cutover.test.mjs
```

The gate parses the checked source directly and requires no checkout-local Git
tree object or path.

Package integration, host deployment, authenticated ntfy/model checks, and
controlled live acceptance remain separate root-owned steps. The current
deployment target is Vermissian, so its Home Manager/NixOS build and switch are
run locally on Vermissian by the root operator. After deployment, the required
target check is that `cc-tools-notifyd.service` is inactive and
`steward-notifyd.service` is active (for example, inspect each with
`systemctl --user is-active`). Gnomon's Home Manager or NixOS closure must
only be built on Gnomon.

## Controlled acceptance checklist

This is an operator checklist, **not an automated acceptance runner or a
record of a successful deployment**. Leave each item unchecked until its
specified evidence exists. Do not infer live success from the synthetic gates.

### Before spending the live budget

- [ ] Record the implementation revision, consumer revision, installed package
  paths, and target system generation. Archive target checkout changes before
  integrating; do not replay historical user overlays because their Pi LSP/tool
  and Claude Astra changes are preserved from deployed user commit 2b1a0eeb85461bccbc42808c94a666eef07aa127.
- [ ] On Vermissian, pull the intended published branch, run the package-backed
  gate above, then build and switch that exact source locally on Vermissian. Do
  not use an `update` command pointing at a different checkout. Gnomon's target
  closure must only be built on Gnomon.
- [ ] Verify the old service is inactive and the canonical service active.
  Check the installed CLI/helper paths, paired Pi extension root and physical
  SDK/AI/TUI/subagents graph, Claude Stop plus usage refresh, and absence of
  deployed legacy notify/SubagentStop commands and compatibility aliases.
- [ ] Check installed client versions and supported flags without launching
  inference. The prepared consumer was checked against Claude 2.1.257 and Pi 0.85.0. Recheck on the target rather than assuming
  local help output proves its installed version.
- [ ] Confirm the effective central provider/model/thinking/helper settings
  agree between the installed daemon script and client configuration. Check
  model availability through public metadata without a completion or auth
  request. Do not silently substitute another model.
- [ ] Inspect only auth-path ownership/mode metadata and necessary nonsecret
  configuration; never parse credentials independently, print bearer tokens,
  dump process environments, or copy auth files into a test fixture. Never use
  Pi's credential-printing CLI commands as a preflight.
- [ ] Record an R1–R8 architecture/scope preflight and fresh component/package
  results for the final implementation. New unapproved ownership, persistence,
  recovery, or protocol mechanisms must be resolved before live acceptance.
- [ ] Prepare an owner-only evidence directory and an empty synthetic project
  with a unique run marker. Keep native hooks and the packaged Pi extension
  enabled. Use a disposable tmux server, not an existing user pane. Keep
  transcripts persistent so Claude has a native terminal-row identity.

### Budget and failure rule

The budget is **one controlled full pass and one focused diagnostic pass**.
Record a pass identifier and its start before the first authenticated quota,
model, or ntfy operation. These calls are live even when their prompt is
synthetic. Normal tests and isolated `hooks/list` metadata probes do not spend
that budget.

Run the following sequence once, serially. Bound each native client run to
120 seconds and each observation window to 30 seconds; terminate only its
owned process/session on timeout. A failed or missing observation is a failure,
not permission to retry, weaken an assertion, or rename another attempt a
preflight. Preserve sanitized evidence, identify the failure, and reserve the
single diagnostic pass for that named issue. Additional passes require explicit
approval. Source fixes must pass their synthetic gates before a diagnostic.

The historical full pass `p5B9555P` succeeded at the configured helper step. A
resumed Claude native Stop used fallback without a completion ID. The single
focused diagnostic D1 confirmed that the correct transcript was read before the
terminal assistant append and verified one received fallback notification. The
new source prevents stale prior-assistant ID/text reuse when a newer user record
exists, but does **not** solve Claude print-mode flush ordering. Pi live
acceptance has not run. The full pass remains incomplete, the focused diagnostic
has been used, and there is no budget reset; further authenticated acceptance
requires explicit approval.

### Full pass

1. **Configured sessionless generation (R4).** Invoke the configured
   `STEWARD_HELPER_BIN` once, feeding a version-1 `compose` request through stdin
   and closing stdin. Use the effective central model settings, two short
   synthetic input strings, and `label: {current: "", refresh: true}`. Follow
   Steward's `docs/pi-helper.md` exact schema. Allow at most 20 seconds at the
   outer process boundary; the helper itself has a 15-second budget. Require
   one successful bounded result with a nonempty body and valid 3–4-word label.
   Record only that safe result, exit status, elapsed time, and configured
   public model identity. Do not pass text or credentials on helper argv.
   Failure fallback is independently covered by the normal tests; fallback
   is not evidence that this live generation check succeeded.
2. **Actual Claude completion (R2–R4).** In the synthetic project, use one
   `claude --tools "" --print --output-format stream-json --verbose` prompt.
   Do not disable session persistence, replace installed settings, or disable
   hooks. Require the existing usage-refresh hook alongside Steward's native
   root Stop. Correlate its native session ID and terminal assistant-row UUID
   with the daemon decision and one received notification. A successful CLI
   exit alone does not prove either hook ran.
3. **Actual Pi root TUI, naming, and quota (R2, R5–R7).** Start the installed Pi
   in the disposable tmux server with `--session-dir` pointing at the owned
   evidence directory and `--no-tools`, then submit one short run-marked
   prompt. Do not use print, JSON, RPC, or child mode; those deliberately do
   not notify or fetch quota. Require the real terminal assistant entry ID,
   settled notification, and shared metadata for the same native session and
   completion. Observe the generated session name and pane `#T`; the tmux
   window name must not change. Set a manual name with native `/name`, wait
   through the remaining bounded metadata-read window, and reopen that same
   session without another prompt. Verify the manual name survives. Record
   the actual observations, not merely the presence of ownership code.
   Observe applicable upstream quota in the real footer and its normalized
   owner-only cache. Capture the footer at widths 40, 60, 80, and a wide
   layout, preserving both windows' remaining/reset/freshness information.
   Missing windows must stay unknown. Never dump auth or raw usage responses;
   keep the nonsecret account key out of the recorded footer. Reopening can
   trigger a quota refresh and remains part of this same recorded live pass.
4. **Attribution and delivery evidence (R2–R3).** For each controlled root
   completion, retain its actual native identity and the matching categorized
   decision from `notify-decisions.jsonl`, filtering only these new sessions.
   An IPC acknowledgement or a decision to notify is not delivery proof:
   additionally confirm the corresponding real ntfy message at the receiver
   or authenticated service, without recording its private URL/token. Record
   message count and content against the same identity. Unexpected duplicates
   in this healthy controlled pass are a failure; do not generalize the
   observation into an exactly-once or crash-durability guarantee.
5. **Cleanup and final state (R1, R5, R8).** Close only the controlled sessions
   and disposable tmux server. Confirm their helpers/watchers do not keep
   them alive, canonical notifyd remains healthy, and the old daemon remains
   inactive. Preserve evidence and unrelated user state. Do not log out,
   switch real accounts, corrupt credentials, or stop the production daemon
   merely to repeat failure cases already covered by isolated tests.

### Required evidence and closure

| Requirement | Evidence to retain |
| --- | --- |
| R1 | Canonical source/package/config inventory; target old-inactive/new-active check; user file/index preservation hashes |
| R2 | Actual Claude and Pi native root completions; retained Claude usage/input hooks and Codex native approval UI |
| R3 | Native IDs linked to received messages; fresh same/distinct/missing-ID, send-failure, SessionEnd, restart and ambiguous-IPC tests |
| R4 | Configured live helper result; pinned minimal-PATH helper tests proving sessionless bounds and deterministic failures |
| R5 | Live Pi session/pane and manual-resume observations; native disk-backed cadence/ownership/lifecycle race tests |
| R6 | Actual pinned generic-child construction and independent/copy negative controls; deployed paired physical graph |
| R7 | Live upstream quota/footer captures; fresh isolated cache/coalescing/auth-watch/account/401/403/freshness/secret-isolation tests |
| R8 | Correct-host build/switch output and exact source/overlay/package/generation identities; final package and consumer gates |

Mark automated and interactive evidence separately. The checklist does not
replace the required full `gambit:review`, closure of admitted required findings,
or the approved release and production verification. A published branch, local
commit, tag, or successful build alone is not completion of this epic.
