# Steward recovery handoff

## 1. Read this first

**Recover the existing implementation; do not restart it.** The destination is a working, packaged, deployed Steward across Claude Code, Codex, and Pi, followed by full review, corrections of required findings, and the release train. Nothing from this effort has been pushed or deployed.

The previous execution spent eight committed waves on foundations and has an uncommitted ninth wave. It accumulated substantial code without completing the client/deployment integration. The user stopped Goal mode and requested a fresh-agent handoff. **This document does not reactivate Goal mode or authorize reuse of a historical goal ID.** No implementation agent remains running from the last wave.

Use the **current** Gambit instructions, not remembered instructions from the previous session. Product requirements below remain binding; old implementation briefs are context, not automatically additional obligations. Local task IDs may not survive the session change.

### Recovery operating rule

Start with a bounded recovery assessment, not another foundation project. Within approximately **45 minutes**, report:

1. What can be retained, what actually blocks integration, and any machinery that can safely be removed.
2. The smallest next runnable integration milestone and the exact remaining delivery path.
3. Observed evidence or a concrete reason that milestone cannot yet run.

That 45-minute checkpoint is a recovery recommendation, not a claim that the whole epic fits in 45 minutes. Do not silently turn it into another open-ended implementation/review cycle. Admit required repairs by evidence; optional improvements are not release blockers. Do not weaken required safety or user-selected mechanisms to achieve speed.

## 2. Authoritative repository state at handoff

Recheck all of this before editing.

| Item | State |
|---|---|
| Consumer repository / this document | `/home/joshsymonds/nix-config` |
| Consumer branch / HEAD | `main` / `377ada6ef01f28ab5ec7c0b920a5b9720d67dd14` |
| Implementation worktree | `/home/joshsymonds/Personal/cc-tools/.claude/worktrees/steward-foundation` |
| Implementation branch | `epic/steward-foundation` |
| Last committed implementation HEAD | `edb77a519a0d7e718b113580fb58d0f01b3f9567` |
| Original cc-tools checkout | `/home/joshsymonds/Personal/cc-tools`, `main` at `b248afef1f09f973c747ffa02c073e6e2bcd78a5` |
| Current active Go/CLI identity | `github.com/Veraticus/cc-tools` / `cc-tools`; coordinated rename is NOT done |
| Historical task state | Epic #3 unfinished; implementation tasks #4–15 completed; #16 uncommitted/unaccepted Pi adapter |
| Production / final acceptance | Not deployed; no controlled live acceptance used |

### Protected user changes

These three paths were already **staged** in nix-config before this work. Preserve their contents and staging; do not sweep them into commits or discard them:

- `home-manager/claude-code/default.nix`
- `home-manager/claude-code/settings.json`
- `home-manager/patchbay/chatgpt-models.nix`

This handoff is a new, intentionally uncommitted file in nix-config. No implementation/Nix consumer changes were made while writing it.

Preserve unrelated utilities, historical state, `~/.claude`, Claude memories, and other worktrees. In particular, do not sweep or prune `cc-toolsd`, `codex-luna-notifications`, `patchbay-route-chip`, `wave-2`, `.claude/`, or external/prunable worktrees. Use exact owned paths when staging or cleaning up.

### Uncommitted wave 9 — preserve and assess

Tracked modifications:

- `package.json`
- `runtime/pi-child-context.test.mjs`
- `runtime/pi-child-probe.mjs`

Untracked implementation files:

- `docs/pi-extension.md`
- `runtime/pi-extension.mjs`
- `runtime/pi-extension.test.mjs`
- `runtime/pi-notify.mjs`
- `runtime/pi-notify.test.mjs`

All are in the implementation worktree, not nix-config. The worker finished; an independent reviewer returned findings, but the root did not complete adjudication or acceptance. **Do not treat these files as reviewed simply because their tests pass.** Preserve the complete tracked AND untracked delta before any reconstruction; plain `git diff` omits the new files.

## 3. Approved product contract

This is a consolidated transfer of the approved Epic #3 requirements. If the old task store is available, its full contract can also be read, but this handoff does not depend on it. Distinguish these obligations from incidental implementation choices.

### R1 — Clean Steward identity and ownership

Rename the active project/repository, canonical Go module to `github.com/joshsymonds/steward`, primary CLI to `steward`, flake inputs/packages/apps, service, environment/configuration prefixes, active sockets/state/cache/log paths, hooks, extension packaging, documentation, and release references. Inventory old-to-new active surfaces before cutover.

No `cc-tools` or `CLAUDE_HOOKS` compatibility aliases, symlinks, or runtime dual lookup. Preserve unrelated utility behavior and historical/user data. Shared package/service/environment/secret-file ownership belongs in `nix-config/home-manager/steward/default.nix`, not the Claude module. Clients retain their adapters. Retire the old daemon so only one canonical service runs. Do not rename `~/.claude` or memories.

### R2 — Deterministic native notifications

Notify on Pi **root TUI `agent_settled`**, Codex **native root `Stop`**, and Claude **root `Stop` plus supported explicit input/permission hooks**. No tool-loop/subagent alerts, model veto, or text-based completion/urgency guesses. Retain only structural active-goal/continuation gates. `SessionEnd` is cleanup, not completion.

Install Claude Stop alongside its usage-refresh hook. Codex uses native Stop only: no legacy `notify` or `SubagentStop` deployment. Keep Codex's native approval UI; trust only Steward's exact command `trusted_hash` at user scope, never a global trust bypass or system-wide managed-hook policy. Remove Claude/Codex inference-CLI judges and LLM watchdog decisions. Explicit input alerts bypass optional inference.

### R3 — Native identity and honest best effort

Versioned normalized events identify harness/session/kind/cwd/completion and carry minimal source text. Pi must not masquerade as Codex. Identity sources:

- Codex: session ID + turn ID.
- Pi: session ID + terminal assistant **entry ID**, captured before extension state append; not current leaf or a fabricated ID.
- Claude: session ID + reliable terminal assistant-row UUID, with nested message ID as documented secondary source.

Missing/unreadable/malformed/empty Claude transcripts or absent reliable identity fail open to an observable bounded fallback, without invented IDs. Atomic in-memory claims dedupe same-ID work, while distinct IDs notify even with identical text seconds apart. Claims are bounded to 24 hours / 10,000 entries, oldest eviction; SessionEnd does not discard recent claims. Explicit send failure permits source retry.

IPC accepted/duplicate/rejected is non-durable local admission. Outage/uncertain acknowledgement gets deterministic inline fallback. Duplicates across ambiguity/restarts and loss around a crash are accepted. No durable outbox, exactly-once promise, or session-wide five-minute quiet window.

### R4 — Central, sessionless Pi generation

A Steward-owned JS helper uses pinned public Pi ModelRuntime APIs for **one sessionless completion**. Initial provider/model/thinking: `openai-codex` / `gpt-5.6-luna` / `low`; centrally configurable, absent-only defaults, no silent model fallback.

No Claude/Codex inference CLI, nested agent, `createAgentSession`, tools, extension loading, whole transcript/system prompt, or memory in the generation helper. Versioned stdin / strict stdout JSON; selected latest user/assistant text bounded to 8 KiB; 15-second total helper budget; 256 output tokens; no generation retries. No transcript or secrets on argv. Generate only after acceptance. Validate result types, lengths, and controls; generated labels have 3–4 words.

Auth/model/timeout/invalid-output failures retain prior label or cwd title and deliver bounded deterministic text, rather than suppressing the event. Accepted notification attribution remains attached to the original session across UI switches.

### R5 — Shared periodic labels and safe Pi application

Request a label after the first completed exchange, then reconsider after each four additional completed exchanges with new material, in the **same** call that composes the notification body. Failed naming keeps the prior label and may retry on the next eligible new exchange, never a busy loop.

Steward persists only minimal label/refresh/source metadata. Pi persists automatic/manual ownership for resume. Retrieve shared metadata asynchronously via local CLI/IPC; apply session/pane naming only if session, branch/source generation, and automatic ownership still match. Preserve manual names and rename races. Invalidate stale UI work on new/resume/fork/tree/reload/shutdown. No helper or timer keeps an exited UI alive. Other harnesses reuse labels in notifications; do not force their terminal titles.

### R6 — Actual Pi root/child boundary

Capture classification at extension construction using the exact pinned pi-subagents child-context accessor and the **same installed module / AsyncLocalStorage instance**. Suppress extension-enabled generic children before enqueue. Broken coupling must be visible, never guessed root. Pin dependencies and test actual generic-child construction, not just mocked flags or Gambit rungs with extensions disabled.

### R7 — Upstream authenticated Codex quota

Only applicable upstream `openai-codex` Pi sessions fetch `https://chatgpt.com/backend-api/wham/usage`. The helper uses public Pi `getAuth` with Pi's OAuth refresh/store locking and derives account identity locally. Bearer credentials stay in that process: no independent auth.json parser/writer, token argv/logs/Go IPC/footer/cache/Nix-store content.

HTTP request/body is bounded to five seconds. Normalize known windows by `limit_window_seconds`, not primary/secondary position. Cache only normalized metrics/timestamps and non-secret account/provider/base-URL key, with owner-only atomic snapshots and coalesced refresh. Refresh every five minutes while applicable; post-settled refresh is bounded/coalesced, never network I/O in rendering.

Transient/429/malformed failures may retain visibly stale last-success values for at most 15 minutes since success, then unknown. Immediately clear on account switch or rejected auth/401/403. Missing windows are unknown, not 100% remaining. Display remaining/reset/freshness in the existing renderer at narrow and wide widths; preserve Claude native rate-limit input and Codex's native quota footer. No generalized billing or gateway guessing.

### R8 — Packaging and coordinated deployment

Steward owns the helper and Pi extension sources/tests currently split with nix-config. Pin compatible Pi 0.85.0 and the selected pi-subagents runtime; resolve physical import/module identity explicitly. Supply Node/helper dependencies under service-like minimal PATH. Secrets remain runtime secret-file values, never Nix-store values. Protect pre-existing user edits/data during cutover.

**Never evaluate/build Gnomon's Home Manager activation or NixOS closure on another host.** Commit/push the intended branch, SSH to `joshsymonds@gnomon`, pull there, and run build/rebuild **inside that SSH session**. Do not invoke a local `nixos-rebuild ... .#gnomon`.

### Exclusions and quality

Shared Claude/Pi memory is a separate deferred epic. No memory migration/recall/writeback/vector store, wholesale suite rewrite, durable messaging service, compatibility layer, new orchestration system, global Codex trust, or historical-data cleanup.

Build the simplest complete implementation of the required behavior. No suppressions, type erasure, disabled/weakened tests, dead code, or unrelated formatting churn. The existing `skipLibCheck` exception is for pinned upstream declarations only; all owned `runtime/*.mjs`, including tests/fixtures, remain strictly checked. High quality does not automatically admit speculative infrastructure or optional review suggestions.

## 4. What is already implemented

These are useful components, **not proof of final product acceptance**:

| Component | Existing implementation / documentation |
|---|---|
| Tolerant Claude native identity scanning; canonical harness parsing | `internal/notify/transcript.go`, `hook.go`, tests |
| Immutable prepared event, strict bounded Frame/Ack, daemon-local claims and fallback | `internal/notify/{event,frame,claims,daemon,pipeline}.go`; `docs/notify-protocol.md` |
| Deterministic completion/input policy; old model judges removed | `internal/notify/decide.go`, `pipeline.go`; normal daemon construction in `cmd/cc-tools/notify.go` |
| Bounded Go → sessionless Pi helper bridge | `internal/notify/pi_composer.go`; `runtime/{compose,cli}.mjs`; `docs/pi-helper.md` |
| Stateless public-auth upstream quota retrieval | `runtime/quota.mjs`; `docs/pi-quota.md` |
| Narrow/wide remaining/reset/freshness renderer | `internal/statusline/quota_render.go`; `docs/pi-quota-footer.md`; goldens |
| Shared periodic label store, cadence, publication guards | `internal/notify/labels.go`, `pipeline.go`; `docs/session-labels.md` |
| Read-only metadata CLI | `internal/notify/label_metadata.go`, `cmd/cc-tools/session_metadata.go` |
| Pinned native child wrapper/classifier and actual construction test | `runtime/pi-subagents.mjs`, `pi-child-context.mjs`, `pi-child-context.test.mjs`, `pi-child-probe.mjs`; `docs/pi-child-context.md` |
| Actual owned Pi notification/footer adapter | **Uncommitted, unaccepted wave 9**, files listed above |

The latest four commits are `7cfb2f8` (claims/admission), `b8c4bc9` (labels), `a366219` (metadata CLI), and `edb77a5` (native child bridge). Read repository history for earlier component commits; do not reconstruct implementation from this prose.

### Important existing boundaries

- `cc-tools session-metadata --harness pi --session-id <native-id> [--state-base <path>]` returns bounded JSON; source/label generations are **decimal strings**, preserving uint64 precision. `known` means validated metadata exists, not delivery/composition completion. See `docs/session-labels.md` before consuming it.
- Normal label cadence is 1/5/9; KEEP is an **omitted wire label**, not the string `KEEP`. Source-generation guards prevent older composition from overwriting newer metadata. Persistence failure preserves prior/cwd notification title.
- Helper defaults already use `STEWARD_HELPER_BIN=steward-pi-helper`, `STEWARD_MODEL_PROVIDER=openai-codex`, `STEWARD_MODEL_ID=gpt-5.6-luna`, `STEWARD_MODEL_THINKING=low`. The rest of the active identity is not yet renamed.
- Acknowledgement precedes optional composition. Ambiguous fallback reuses the prepared source snapshot; accepted work is not a durable delivery receipt.

## 5. Uncommitted review candidates — adjudicate, don't blindly schedule

The last independent reviewer reported these three gaps. A handoff inspection confirmed the cited source patterns still exist, but no remediation, complete root adjudication, or final combined gate followed. Apply current Gambit admission rules and inspect supported/reachable behavior.

1. **Actual-child adapter proof uses self-reported constants.** `runtime/pi-extension.mjs:464–477` reports literal registration/enqueue counters; `runtime/pi-child-probe.mjs:411–416` checks them; the construction test trusts those booleans. The existing actual module/ALS construction proof is valuable, but these added counters do not independently prove the adapter's real registration/enqueue behavior. R6 requires actual suppression evidence. Prefer externally observed behavior and a meaningful negative control; remove test-only production machinery if unnecessary.
2. **Newline-only footer output can erase the last good line.** `runtime/pi-extension.mjs:241–247` checks stdout nonempty before trimming trailing newlines. Review the expected recovery contract, normalize before accepting a candidate, and test the behavior if admitted.
3. **Zero exit can settle success before stdin failure is observed.** `runtime/pi-notify.mjs:127–179` settles immediately on exit code zero, while a later stdin callback failure becomes a no-op. Check the reachable process/write ordering and required transport outcome; if admitted, add a deterministic ordering regression and require the necessary completion signals before success.

Do not turn this list into a new open-ended audit or claim the findings were already fixed. The full final review still has not run.

## 6. Integration facts that save repeated investigation

### Native Pi dependency identity

Pinned dependencies: coding-agent/server/AI/TUI **0.85.0**, `@tintinweb/pi-subagents` **0.19.0**, TypeScript **5.9.3**, Node types **24.10.0**. Node **24** is the tested runtime.

The Pi SDK's npm shrinkwrap recreates nested AI/TUI copies even with matching outer pins. Matching version numbers alone do NOT prove shared runtime identity. Current reproducible setup is:

```sh
npm ci --ignore-scripts
npm run prepare:pi-runtime
```

`runtime/prepare-pi-runtime.mjs` validates the exact installed root/nested packages and removes only the two generated SDK-nested peers, so the active graph resolves shared root peers. CI explicitly calls it. Do not replace the positive construction test with an artificially aligned copied fixture.

The wrapper uses Node `createRequire` to load compiled `dist/index.js`; the classifier loads the same physical compiled `dist/child-context.js`. Jiti-loading `src/index.ts` is NOT the same module identity. Pi must load the owned wrapper instead of the package's original extension entry. Future Nix packaging must bind native peers to the **TUI's physical runtime graph**, not silently bundle another in-process SDK. This packaging proof is still outstanding.

### Auth invalidation

Prior sanitized synthetic experiments demonstrated that public Pi login, same-provider account switch, and logout caused metadata-only parent-directory `fs.watch` invalidation of auth.json on the observed Linux runs. Public extension model/session events alone do not cover account changes.

This was a feasibility probe, not a production cache. Watch setup/error failures must fail closed to unknown; use generation/watch-health checks and metadata revision fences around asynchronous work, including **after the final awaited stat**. Do not independently parse credentials, claim lossless OS events, or call polling an immediate signal. Producer/cache integration is still unimplemented.

### UI facts

The existing custom Pi footer ignores `setStatus`; quota must flow into its existing renderer payload. Tmux displays pane `#T`, not the window name. Pi `agent_settled` is the structural completion boundary; its event has only `type`. Capture terminal assistant entry identity from the branch before custom metadata changes the leaf. Manual naming provenance needs actual session-info/ownership handling; do not invent a public name-change provenance API.

### Existing consumer/reference paths

- `nix-config/home-manager/pi/{cc-tools.ts,cc-tools.test.ts,default.nix}` — old active adapter/packaging, not migrated.
- `nix-config/home-manager/claude-code/{default.nix,settings.json}` — protected existing staged changes; current Claude ownership/hooks.
- `nix-config/home-manager/codex/managed-config.nix` — current Codex wiring.
- `nix-config/.reference/codex/codex-rs/` — native Stop/trust source reference; source inspection is not live trust acceptance.
- Pinned Pi install previously inspected: `/nix/store/qyrj80r03y3dbpmz4mhx9mclm5b2y480-pi-coding-agent-0.85.0/lib/node_modules/pi-monorepo`. Store paths may disappear; resolve installed package paths if needed and read current relevant public Markdown completely before API use.

## 7. Verification already recorded, and what it does NOT prove

Last committed combined wave gate, at `edb77a5`:

- Full Go race/count=1 suite: all 11 tested packages passed.
- Full golangci-lint: zero issues; deadcode, formatting and diff checks passed.
- Fresh npm ignored-script install plus explicit preparation; 91 Node tests passed, strict typecheck passed, audit reported zero vulnerabilities.
- No executable pre-commit hook was installed in cc-tools; declared checks still ran.

Uncommitted wave 9: root reran **48 focused tests** and strict typecheck successfully before review. Those passing tests do not resolve the proof gaps above. No final combined wave-9 gate or commit occurred.

The old checkpoint recorded only **1/10 complete end-to-end success criteria** (native-ID/best-effort tests). This is not a percentage estimate of remaining coding effort; it demonstrates delayed end-to-end integration.

Optional historical evidence, present when this handoff was written:

- `/tmp/steward-wave8-integration.log` — combined gate and atomic integration output.
- `/tmp/steward-wave8-final.patch` — complete committed wave-8 diff.
- `/tmp/steward-wave9-review.patch` — frozen tracked/untracked wave-9 review diff.
- `/tmp/steward-wave7-child-proof/` and `/tmp/steward-wave7-child-root-verification.json` — original child feasibility experiment.
- `/tmp/steward-wave7-auth-proof/` and `/tmp/steward-wave7-auth-root-verification.json` — synthetic auth-signal experiment.

Temporary artifacts may vanish. The source/tests/git history are durable; rerun current checks for new claims. Do not load every old log and transcript before doing useful work.

### Fresh component gate when required by the current workflow

From the implementation worktree, after assessing/preserving its dirty state:

```sh
npm ci --ignore-scripts
npm run prepare:pi-runtime
node --test runtime/pi-extension.test.mjs runtime/pi-notify.test.mjs runtime/pi-child-context.test.mjs
npm run typecheck
# Full integrated gate, not a ritual repeated for each tiny repair:
go test -race -count=1 ./...
GOLANGCI_LINT_CACHE="$(mktemp -d /tmp/steward-lint.XXXXXX)" golangci-lint run
deadcode -test ./...
npm test
npm audit
# Also inspect formatting and complete tracked/untracked diff, without formatter churn.
```

Use a fresh task/wave-local lint cache: shared caches previously produced stale diagnostics referring to removed worktrees. Do not suppress diagnostics or edit unrelated code to compensate. The command is `deadcode -test ./...`, not `deadcode-test`.

## 8. Remaining delivery and completion checklist

Do not turn every bullet into a separate prerequisite wave. Choose runnable delivery slices and reuse existing components.

- [ ] Inventory and complete canonical rename; shared Steward Nix module owns package/service/environment/runtime secret file; consumer cutover retires the old daemon with no compatibility runtime.
- [ ] Actual trusted native Codex Stop, Claude Stop plus usage refresh, and Pi settled root paths work; children/tool loops remain silent; supported explicit input alerts are prompt.
- [ ] Current tests prove same/distinct/no identity, send-failure retry, SessionEnd, restart and ambiguous-IPC behavior without durability claims.
- [ ] Packaged configured Pi one-shot generation uses no agent/tools/hooks/memory/fallback model; invalid/auth/timeout outcomes still notify deterministically.
- [ ] Pi label application implements persistent manual/automatic ownership, resume, first/four-exchange/retry cadence consumption, pane/session naming and stale async lifecycle guards while preserving original notification attribution.
- [ ] Actual pinned generic-child construction proves adapter suppression and shared native module identity, not just a mocked marker or reported constants.
- [ ] Quota cache/coalescing/auth watch/account invalidation/freshness/unknown/secret isolation and footer producer are integrated; 40/60/80/wide rendering and packaged minimal-PATH smoke pass.
- [ ] One controlled live acceptance pass verifies configured helper inference, one real completion notification per harness, actual Codex trust, Pi naming/manual override and upstream quota against the final built revision.
- [ ] All relevant Go/Node/type/lint/deadcode and applicable Nix package/consumer gates pass on the integrated result; installed hooks run, or their absence is recorded.
- [ ] Full current `gambit:review` completes; confirmed findings are admitted against required behavior/evidenced failures, required ledger entries are closed, and the actual release train deploys and verifies production.

The declared package gate is `nix build .#default --no-link` in the implementation tree on the current host, plus packaged helper smoke under minimal PATH using local fakes. This is **not permission to instantiate Gnomon's target closure locally**. Nix consumer changes need syntax/targeted assertions and the correct host-specific build/deployment.

Final acceptance was planned as a requirement-owned `tests/acceptance/run.mjs --live` opt-in runner/checklist; it does not exist yet. Record interactive observations honestly rather than claiming the script performed them. Normal tests use synthetic fixtures/local processes/sockets/HTTP fakes, not private transcripts or real credentials/model/ntfy calls.

**Live budget: one controlled full pass and one focused diagnostic pass; zero used.** Run architecture/scope preflight and fresh component/package checks before spending it. An early runnable integration milestone should use actual owned paths/binaries with synthetic inputs and local fakes, not covertly consume live acceptance.

The release-train workflow was **not loaded or run** in the previous session. Locate the project's real release procedure when reaching that stage; do not equate local commits or `finishing-branch` alone with deployed production. Respect release authorization and repository operating notes.

## 9. Updated Gambit: apply the fixes, not the old loop

Repository: `/home/joshsymonds/Personal/gambit`, clean at `53033e9` when inspected.

- `53033e9` separates verified observations from mandatory scope. Admission requires an approved requirement/existing obligation or concrete evidenced correctness/security/operational failure. Optional improvements remain true but non-blocking. Choose a runnable delivery slice before parallel decomposition. A newly named prerequisite is NOT a convergence-resetting blocker. Unrequired machinery may be removed rather than hardened if required guarantees remain satisfied.
- `20df44f` tests whether existing skills themselves cause regressions using matched unaided/current/edited conditions. Restoring unaided good behavior can be a valid repair; extra ceremony is not improvement.

Read current `skills/executing-plans/SKILL.md`, `skills/review/SKILL.md`, and model/worker contracts when applicable. Do not grandfather old reviewer suggestions or invented prerequisites into immutable requirements. The original user-selected mechanisms and safety/compatibility guarantees above still bind.

Previous routing used Astra as orchestrator and frequently Sol `xhigh` as worker AND reviewer. The last worker took about 20 minutes/112 tool calls, followed by 8 minutes/68 calls of review, while the focused tests took about 1.6 seconds. Reserve high effort for a demonstrated need rather than assuming every boundary needs it; resolve current configured roles normally. The prior `opus` alias was unavailable and a `deep` alternative failed before tools; those are historical observations, not reasons to edit global model configuration.

### Suggested prompt for the fresh agent

> Read `/home/joshsymonds/nix-config/STEWARD-RECOVERY.md`. Recover this existing implementation; do not restart it. Use the updated Gambit workflow and preserve the complete product destination, user edits, and existing work. First perform the bounded recovery assessment and report the next runnable integration milestone within 45 minutes. Distinguish required repairs from optional improvements; do not create another chain of independently polished foundations. Then carry the admitted implementation, verification, review and actual release work through the agreed checkpoints. Do not assume historical Goal mode is active.
