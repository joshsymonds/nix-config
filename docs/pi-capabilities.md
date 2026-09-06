# Pi capabilities for Gambit

Research snapshot: **2026-09-06**. Recommendation: keep upstream Pi and Gambit;
add focused capabilities, not another planning/task/continuation framework.
Installed on Vermissian: pi-lsp plus the three approved extensions below.
Plannotator was declined because conversational planning/review already fits Gambit.
Hermes, interactive-shell, OMP, and shared-memory development remain out of scope.

## Personal prompt and communication

`home-manager/pi/AGENTS.md` is the Nix-managed personal instruction source, loaded
through `programs.pi-coding-agent.context`. It supplements Pi's built-in system
prompt rather than replacing it, preserving dynamic tool metadata and guidance.
The old 120-word/8-line cap and files-and-verification-only rule are removed.

The approved guidance combines the relevant Claude Code defaults with the user's
personal policy: readable outcome-first prose; concrete user-action endings only
when input is needed; orientation before tools and meaningful intermediate status
updates; useful rationale and uncertainty without private deliberation; full-scope
execution, evidence-based reporting, real browser validation, and concurrent-work
care. Existing process/web/browser and Gambit ownership boundaries remain intact.

`prompt.smoke.mjs` checks the generated instructions and built-in/tool prompt
composition without a model call. It verifies wiring/content, not model adherence
or periodic updates during a single blocking tool invocation.

```sh
node home-manager/pi/prompt.smoke.mjs "$pi_root" ~/.pi/agent/AGENTS.md
```

## Installed: processes, web access, and browser automation

Run `/reload` or start a new Pi session. Pi remains **0.85.0**; no upgrade was
needed for these packages. Existing Gambit agents keep their extension restrictions.

| Package | Installed version | Entry point |
|---|---|---|
| @aliou/pi-processes | 0.12.0 | `process`; `/ps`, `/ps:logs`, `/ps:kill` |
| pi-web-access | 0.28.0 | `web_search`, `fetch_content`, `get_search_content`, `source_check` |
| pi-agent-browser-native | 0.6.6 | `agent_browser` |
| Upstream native agent-browser | 0.36.0 | Nix-managed `~/.local/bin/agent-browser` |

`home-manager/pi/tool-packages/` locks the complete process/web dependency graph.
Nix installs it offline without npm lifecycle scripts or auto-installed SDK peers.
`agent-browser.nix` packages the upstream native executable (static musl on Linux)
and Nix Chromium; no npm browser installer, Playwright download, or Pi fork.

### Defaults and boundaries

- Process output can wake/steer Pi for explicit readiness/error/exit conditions.
  Routine server success should use `context`, not `turn`. Gambit still owns
  acceptance; cc-tools still owns external notifications. Status widgets default
  off, dock closed, and bash interception off. Processes die with the session.
- A narrow packaging patch removes pi-processes' **project-local settings scope**:
  its upstream loader reads project `shellPath` even without Pi project trust.
  Only global/in-memory process settings are allowed; the integration test supplies
  an invalid untrusted local shell override and verifies the global shell runs.
  Config version 0.10.6 is stamped to avoid migrations writing to the Nix store.
- Search defaults to **keyless Exa**, with `workflow: "none"`. No automatic Codex
  provider selection, curator, or additional answer-model summary. Search queries
  still go to Exa; do not send private transcripts/work material. The public MCP
  endpoint can rate-limit. DuckDuckGo's HTML endpoint challenged this host during
  research, so it was not chosen as the default.
- Fetching defaults to **direct HTTP**, with hosted fallback providers and browser
  cookies disabled. PDFs use local Unpdf extraction and return a saved Markdown
  artifact. Automatic GitHub cloning/`gh` auth reuse and video/image model routes
  are off. For very short pages, readable extraction can reject the content; use
  `mode: "raw"` or the browser instead of enabling credentialed fallbacks.
- `web-search.json` is managed at the legacy, XDG, and agent-dir locations used by
  this published version. All copies have identical non-secret defaults. Explicit
  per-call overrides or future credential environment variables are not a security
  boundary; instructions require approval before changing these routes.
- Browser sessions use **separate temporary Chromium profiles**, removed on close.
  The native launcher clears inherited agent-browser profile/provider/CDP/restore
  defaults and pins an explicit browser configuration. Script mode receives the
  same defaults after stripping its inherited browser environment. No automatic
  attachment to a personal Chrome profile; no second web-search provider.
- Explicit CLI flags can override browser defaults: this is not sandboxing or
  permission to send, publish, purchase, or deploy. Linux runtime was verified;
  Darwin evaluates but requires a separately installed Chromium application at
  `/Applications/Chromium.app/Contents/MacOS/Chromium` and is not runtime-tested.

### Activation and verification

Activated **eight Pi-only Home Manager-style links**, not a full Home Manager or
system switch. No unrelated staged Claude Code/Patchbay changes were deployed.
The GC root is `~/.local/state/pi/workflow-home-files`; prior settings/instructions
are backed up under `~/.local/state/pi/before-workflow-tools-_pt1mlcy/`.

Verification on Vermissian:

- Actual Pi CLI startup (`pi --no-session -p '/lsp'`), package listing, and native
  `agent-browser --version` succeeded.
- `tools.smoke.mjs`: **8/8**—real process readiness/steering, stdin/logs,
  context-only success, nonzero failure, stop, untrusted config rejection,
  shutdown/temporary-log cleanup; HTTP raw/readable/redirect/404 behavior;
  public Exa search and stored-result retrieval; local PDF extraction.
- `browser.smoke.mjs`: real local page open → snapshot → reference click → changed
  snapshot → genuine PNG screenshot; concurrent script uses a separate profile
  and leaves the managed session intact; close removes profiles. No model calls.
- Existing LSP smoke: **6/6**; cc-tools tests: **5/5**; Nix builds, Alejandra,
  JavaScript syntax and whitespace checks succeeded.

```sh
pi_root="$(nix eval --raw '.#homeConfigurations."joshsymonds@vermissian".config.programs.pi-coding-agent.package.outPath')/lib/node_modules/pi-monorepo"
node home-manager/pi/tools.smoke.mjs "$pi_root" ~/.pi/agent/settings.json \
  ~/.pi/agent/web-search.json ~/.pi/agent/extensions/processes.json
node home-manager/pi/browser.smoke.mjs "$pi_root" ~/.pi/agent/settings.json ~/.local/bin
```

These are actual tool/SDK integration tests, not model adoption or interactive
TUI overlay tests. Web smoke uses public network endpoints and can fail if those
services are unavailable. No tests sent private content or invoked a model.

## Installed: targeted LSP feedback

`home-manager/pi/default.nix` pins **@narumitw/pi-lsp 0.49.7** and configures
Nix, Python, TypeScript/JavaScript, and Go using existing language servers from
the Helix configuration. Pi supplies the package's only runtime peer, TypeBox.
No npm lifecycle scripts or language-server installers run during packaging.

- Tools: `lsp_diagnostics`, `lsp_fix`; command: `/lsp`.
- Run `/reload` or start a new Pi session to load it.
- Diagnostics are requested explicitly, not injected after every edit.
- Fixes preview by default. Avoid concurrent writes: upstream fix writes bypass
  Pi's mutation queue and have no stale-file check.
- **Not IDE navigation:** no definitions, references, or semantic rename.
- **TypeScript limitation observed:** its organize-imports action did not produce
  edits through this extension; command-based actions are unsupported. Go's
  WorkspaceEdit-based import cleanup produced a real non-writing preview.
- TypeScript automatic typing acquisition is disabled and tsserver is Nix-pinned.
- nixd gets an empty nixpkgs expression and no host-option expressions, rather
  than the editor's expensive host completion setup. Never use this to evaluate
  Gnomon's closure on Vermissian.
- Gambit's rung agents retain `--no-extensions`. This is a parent capability;
  workers still use repository checks. Enabling richer tools in a particular
  scout must be explicit, not a blanket relaxation of worker restrictions.
- LSP servers retain normal user authority and environment. This configuration
  is not a sandbox or a general guarantee against network/evaluation activity.
- Clean diagnostics do not replace the project's tests/typecheck/build.

Source: [published package](https://registry.npmjs.org/@narumitw/pi-lsp/0.49.7),
[README/settings](https://github.com/narumiruna/pi-extensions/tree/main/packages/pi-lsp).

### Verification and local activation

Built only Vermissian's two Pi configuration sources and the small extension
package, **not** a system or Home Manager activation closure. Activated those two
symlinks only, so unrelated staged Claude Code/Patchbay changes were not deployed.
A GC-rooted, two-file `home-manager-files` link farm lives at
`~/.local/state/pi/lsp-home-files`; the previous settings symlink is backed up in
`~/.local/state/pi/before-pi-lsp-63qw5h06/`. Normal Home Manager activation can
subsequently take ownership of the links from the declarative source.

Fresh checks on Vermissian / Pi 0.85.0:

- Nix package/config builds succeeded; `pi list` reports pi-lsp 0.49.7.
- `pi-lsp.smoke.mjs`: **6/6 passed**. Existing package extensions load together;
  all four configured commands resolve; each language detects a planted error
  and clears it after repair; Go preview changes text without writing the file.
- Existing `cc-tools.test.ts`: **5/5 passed**.
- Alejandra and `git diff --check` passed.

Reproduce against the installed Pi package and configuration on Vermissian:

```sh
pi_root="$(nix eval --raw '.#homeConfigurations."joshsymonds@vermissian".config.programs.pi-coding-agent.package.outPath')/lib/node_modules/pi-monorepo"
node home-manager/pi/pi-lsp.smoke.mjs "$pi_root" \
  ~/.pi/agent/settings.json ~/.pi/agent/pi-lsp.json
node --test home-manager/pi/cc-tools.test.ts
alejandra --check home-manager/pi/default.nix
git diff --check
```

This is a real-server integration smoke test, not an exhaustive upstream test
suite, model-driven adoption test, TUI lifecycle test, or worker integration test.

## What the transcript research changes

A scout inspected **71 Claude Code/Codex transcripts**, spanning July–September
and personal, infrastructure, Gambit, product, writing, and work projects. Sampling
was stratified across projects and time, not a frequency census. Codex archives
contain extensive automated traffic; interactive user messages were distinguished
from tool output, synthetic prompts, pasted assistant advice, and duplicate events.
No transcript content was uploaded or used as a web-search query.

The recurring desired experience is **observable autonomy that actually lands**:

1. Know which agent owns a task/worktree, its actual model/effort, and whether it
   is making progress. A final-answer model label is too late.
2. Find previous decisions and artifacts with source citations. Saving sessions
   already works; retrieving the right old conversation is the missing layer.
3. Notify only for decisions, blockers, stalls, or verified completion—not every
   model turn. Existing cc-tools already supplies footer/settled notifications.
4. Bound reviews and get to a shipped increment rather than endlessly preparing.
5. Compare inexpensive model attempts empirically, with test evidence and budgets.
6. Support research, product analytics, visual work, fleet operations, and mobile
   assistance—not just code editing. Keep private data and authorship boundaries.

Private, sanitized evidence and the fuller external-source inventory are retained
under `~/.local/state/pi/research/2026-09-06/`, not committed with transcript excerpts.

## Ranked installation candidates

Versions below are the published versions checked during research. They are pins
for a future trial, not an instruction to install the whole table.

| Priority | Candidate | Why it fits | Conditions before adoption |
|---|---|---|---|
| Installed | [pi-web-access 0.28.0](https://github.com/nicobailon/pi-web-access) | Native search/fetch/PDF tools; `source_check` records claim evidence with passage offsets and content hashes. Strong fit for architecture research and adversarial verification. | Explicit provider/privacy routes; disable interactive curator with `workflow: "none"` for unattended scouts. Extra summaries can cost model calls. Published version uses `~/.pi/web-search.json`, unlike current HEAD docs. |
| Installed | [pi-agent-browser-native 0.6.6](https://github.com/fitchmultz/pi-agent-browser-native) | Real accessibility snapshots, screenshots and browser actions: test mobile layouts, verify UI behavior, collect visual evidence. Much more useful than restoring another search command. | Separately package Vercel `agent-browser` and Chromium dependencies in Nix; dedicated profile. Browser actions can affect real accounts. |
| Declined | [@plannotator/pi-extension 0.27.12](https://github.com/backnotprop/plannotator/tree/main/apps/pi-extension) | Visual document annotations and line-level review are real features, but the user prefers discussing plans directly with Gambit agents. | Not installed. Revisit only if visual annotations become a concrete need, not for planning parity. |
| Installed | [@aliou/pi-processes 0.12.0](https://github.com/aliou/pi-processes) | Dev servers/test watchers with readiness, errors, logs, stdin and exit notifications. Adds process supervision rather than a second task DAG. | Overlap assessed below: existing TaskOutput/TaskStop have no wired-up arbitrary-shell launcher. Prefer this for structured process events; retain cc-tools notifications and Gambit approval boundaries. |
| Defer | [pi-hermes-memory 0.9.8](https://github.com/chandra447/pi-hermes-memory) | Pi session search with FTS5 and optional file/line anchors; relevant functionality, but not the right shared-memory solution here. | **Pi history only, not a Claude/Codex importer.** Mentat has conversation continuity, not an existing retrieval index. Prefer shared, cited cross-harness retrieval over another autonomous memory/skill authority. |
| 6 | [pi-interactive-shell 0.15.2](https://github.com/nicobailon/pi-interactive-shell) | Observable PTYs and human takeover for SSH, database consoles, and interactive debugging. Particularly relevant to fleet operations. | Alternative to pi-processes when interactive control is the need. Package zigpty correctly; avoid its child-agent orchestration path. |
| 7 | [@llblab/pi-telegram 0.43.2](https://github.com/llblab/pi-telegram) | Phone prompts, voice/images and completion messages attached to a running session. Practical way to try mobile supervision now. | Fixed numeric owner ID; never first-contact pairing on an exposed bot. Bot traffic is not E2E-encrypted. Prefer a Mentat integration long-term if that should remain the personal-assistant surface. |

**The approved set is now installed: process supervision, web access and a browser.**
Plannotator was dropped rather than duplicating conversational Gambit planning.
Session retrieval remains separate: the multi-harness archive needs more than
installing a Pi-only memory package.

### Useful collections and measured popularity

GitHub stars are a discoverability signal, not evidence of compatibility or Pi
extension adoption. Snapshot from primary GitHub API metadata:

- [oh-my-pi](https://github.com/can1357/oh-my-pi): **29,737** stars.
- [Plannotator](https://github.com/backnotprop/plannotator): **8,468**; whole product,
  not specifically its Pi extension.
- [mitsuhiko/agent-stuff](https://github.com/mitsuhiko/agent-stuff): **3,058**;
  select `session-breakdown.ts` for local model/token/cost analysis. Do not load
  the whole collection's alternate goals/subagents/todos/tool replacements/trust hooks.
- [pi-mcp-adapter](https://github.com/nicobailon/pi-mcp-adapter): **1,421**;
  lazy discovery/proxy for existing MCP integrations, rather than loading every
  server schema into context. Useful for Mentat/data tools when needed.
- [pi-web-access](https://github.com/nicobailon/pi-web-access): **1,375**.
- [pi-web](https://github.com/jmfederico/pi-web): **715**.
- [tmustier/pi-extensions](https://github.com/tmustier/pi-extensions): **474**;
  selectively consider files/diff widgets, tab status, and session recap.

Recent pushes were checked, but a pushed timestamp can describe any branch, not a
release. The complete private source inventory records package versions and dates.

### Compatibility and things to skip for now

Your installed host is **Pi 0.85.0**. Several apparently current plugins are not
straightforward drop-ins:

- **pi-web 1.202609.0 explicitly excludes 0.85.0** (published SDK loading issue);
  align/test a Pi upgrade before using it as a remote session daemon.
- Published peer ranges for pi-mcp-adapter 2.32.1, pi-lens 4.1.3,
  pi-background-tasks 2.5.0 and pi-sandbox 0.6.6 exclude 0.85.x. This is a
  compatibility warning, not proof that all fail at runtime.
- [pi-lens](https://github.com/apmantza/pi-lens) has richer semantic intelligence,
  but auto-install/auto-format/guard machinery is a much larger adoption surface.
- [pi-background-tasks](https://github.com/ismailsaleekh/pi-background-tasks)
  includes delegation/Fusion and Anthropic prompt/cache behavior—not just background bash.
- Do not add another planner, goal loop, subagent manager, or monolithic bundle.
  You already have pi-tasks, pi-subagents, pi-goal, and Gambit contracts.
- No second footer/notification replacement: extend cc-tools where needed.
- Avoid always-on automatic memory, skill generation, and external prompt tracing
  until provenance, project exclusions, retention, and redaction are settled.
- [pi-sandbox](https://github.com/carderne/pi-sandbox) is not containment around
  trusted extensions, arbitrary MCP children, browser tools, or the entire Gambit
  process tree. Strong isolation belongs around the whole process tree.

## Follow-up: overlap with the installed tools

Source inspection, not a runtime trial of either proposed process extension.

| Need | Existing setup | Meaningful addition |
|---|---|---|
| Parallel coding/research, task dependencies, worker steering/results | Gambit + pi-tasks + pi-subagents already own this | None; avoid competing agent dispatchers |
| Arbitrary background command | tmux works; TaskExecute launches agents, not commands | pi-processes gives the model named process handles without delegating to another LLM |
| Live shell logs and readiness/error/exit events | tmux capture/manual inspection; no configured Pi wake bridge found | pi-processes supplies log queries and explicit event watches |
| Interactive SSH/psql and human takeover | tmux already supplies real terminals | pi-interactive-shell integrates PTYs and takeover into Pi's UI; pi-processes has pipes, not a PTY |
| Survive Pi exit; restart a service after failure/reboot | tmux for disconnect survival; systemd for supervised services | Neither proposed extension is a durable service supervisor |
| External notifications | cc-tools + notifyd already handle settled notifications/delivery | No new notification owner needed |

**Important correction to the tool descriptions:** installed pi-tasks 0.9.0
advertises background shells in TaskOutput, but its `ProcessTracker.track()` has
no caller under `src/`. The tracker is only queried/waited/stopped in `src/index.ts`
(around lines 987, 1041, 1076). TaskExecute starts subagents. Agent steering is not
shell stdin; agent transcripts are not shell-log handles. This is an unconnected
capability, not a usable background-shell launcher in the current setup.

**Recommendation: pi-processes is a justified addition** for long builds, dev
servers and watchers while the parent continues useful work. Keep tmux/systemd
for jobs that must survive Pi. Defer interactive-shell unless in-Pi terminal
handoff becomes a frequent need; do not install both initially.

Integration constraints:

- Process readiness/exit is evidence, not task acceptance or checkpoint approval.
- pi-processes `turn` attention uses steering plus `triggerTurn`; prefer context
  delivery for routine chatter and wake only for authorized conditions. Extra
  agent turns can create extra settled notifications through existing cc-tools.
- Both extensions keep an in-memory process registry and kill managed processes
  on session shutdown. pi-processes deletes its temporary logs then; its logs
  are capped, not archival evidence.
- interactive-shell dispatch defaults include quiet auto-close. Silence is not
  command success; disable that behavior for builds/gates. Its prompt guidelines
  also encourage agent delegation, which would need constraining for Gambit.
- tmux survives Pi exit, but the configured orphan reaper kills sessions after
  48 hours idle. It is not indefinite job retention.

Evidence: installed pi-tasks `src/index.ts:966–1090,1177–1187` and pi-subagents
`src/agent-runner.ts:961–1008`; local `home-manager/pi/cc-tools.ts:168–204` and
`home-manager/tmux/default.nix:196–216`;
[pi-processes notifications](https://github.com/aliou/pi-processes/blob/16c1080030e5efd175a268e44ce665fb97bcb68f/extensions/processes/notification-sender.ts),
[cleanup](https://github.com/aliou/pi-processes/blob/16c1080030e5efd175a268e44ce665fb97bcb68f/extensions/processes/hooks/cleanup.ts),
[interactive-shell published source](https://github.com/nicobailon/pi-interactive-shell/tree/eedb89a9e4618d7416326d9387085a756a2125ee).

## Follow-up: Hermes versus Mentat

**Mentat is an assistant daemon today, not yet a shared-memory/search service.**
The checkout at `~/Personal/mentat` is `bd7a786`; the Nix-pinned revision is
`15f9d21`, 20 commits later. Both were inspected so the older checkout would not
hide the pinned Android/voice-token implementation. Configuration was inspected;
live deployment and phone functionality were not verified.

| Capability | Mentat implemented | Hermes 0.9.8 documented |
|---|---|---|
| Conversation continuity | Persistent Claude SDK sessions and a restart-safe resume map | Pi already owns its sessions |
| Facts/preferences CRUD | Upcoming; `MENTAT_MEMORY_DIR` only grants directory access | SQLite/Markdown memories and categories |
| Search historical conversations | No owned index, importers or search endpoint | Pi-session FTS5 and optional JSONL line anchors |
| Claude/Codex/Pi archive coverage | No cross-harness connectors | Pi only documented |
| Automatic learning/skill generation | Not implemented | Reviews, correction capture, consolidation, generated skills |
| Voice/mobile/reminders | HA, LiveKit, Android in pinned revision, daily calendar reminder | Not the package's purpose |
| Pi access | No configured Pi integration; HTTP conversation API, not retrieval | Native tools over its own Pi-local store |

Mentat consumes MCP tools; it does not currently expose a memory MCP server.
Calling its conversation endpoint from Pi would ask another model a question,
not provide deterministic, cited retrieval. Tests containing `memory_save` names
exercise protocol translation, not a memory implementation. Likewise, voice
persona text saying Mentat "holds memory" is not evidence of a retrieval engine.

**Defer Hermes.** It would add real functionality, so "Mentat already does all of
this" would be wrong. But it does not fill the main cross-harness search gap and
would introduce another fact store, standing-instruction file, generated skill
library and automatic learning policy alongside Gambit and a future Mentat store.

The better ownership split is:

1. **Evidence:** existing NAS transcripts, with role/origin filtering, project and
   worktree identity, session lineage, exclusions, retention, and source anchors.
2. **Curated knowledge:** deliberately promoted, sourced preferences/decisions in
   one shared store. It could be a Mentat subsystem, but retrieval should not
   require launching an assistant conversation.
3. **Instructions and procedures:** repository instructions/tool guards and
   Gambit—not facts silently promoted into executable workflow policy.
4. **Consumers:** Pi for coding/research; Mentat for voice/mobile/reminders. Both
   should query the same evidence instead of growing separate memory silos.

This enables the actual recurring requests: find an old rubric, resume a project's
work with evidence, ask project status by voice, and generate cross-project
briefings. Start with local cited search, not autonomous fact extraction.

Privacy: local storage or tailnet ingress does not mean local-only processing.
Mentat uses Claude and hosted voice services; Hermes learning adds model calls.
Neither inspection established pre-transmission redaction for an indiscriminately
indexed archive. Work/private boundaries must be explicit.

Evidence: Mentat `README.md:19–21`, `src/claudecode.ts:200–216,381–417,626–651`,
`test/claudecode.test.ts:569–591`; pinned `15f9d21:src/server.ts:79–109`;
`hosts/ultraviolet/services/mentat.nix`; published
[Hermes 0.9.8 metadata](https://registry.npmjs.org/pi-hermes-memory/0.9.8).
Detailed notes are retained privately at
`~/.local/state/pi/research/2026-09-06/mentat-overlap.md`.

## What oh-my-pi actually offers

[Oh My Pi v18.1.11](https://github.com/can1357/oh-my-pi/tree/v18.1.11), released
September 5, is a **different harness**, not an upstream Pi plugin pack. Its CLI is
`omp`, package `@oh-my-pi/pi-coding-agent`. It uses Bun and substantial native Rust
components and has its own Nix flake/Home Manager module.

Released capabilities worth caring about:

- Built-in LSP navigation/rename/diagnostics **and a DAP debugger** with stepping,
  stack frames and variables. The debugger is a genuinely different capability
  from diagnosing code through grep and test output.
- Integrated search, browser/CDP and native desktop interaction.
- Persistent shell/background jobs; live Agent Hub with worker transcripts,
  steering, kill/revive; structured worker yields and isolation backends.
- Hashline editing, AST operations, persistent Python/JavaScript cells that can
  invoke tools, and file-shaped resources such as `pr://` and `agent://`.
- Local stats dashboard for model/tool cost, cache, latency and failures.
- Optional memory backends; memory defaults off. Its basic `local` mode does not
  itself expose structured recall/search tools; backend choice matters.
- Encrypted terminal/browser collaboration with QR links and read-only or writable
  guest authority. **The production relay's source and binaries are not distributed**;
  the repository's development relay is not a production self-hosting replacement.

Sources: [release README](https://github.com/can1357/oh-my-pi/blob/v18.1.11/README.md),
[memory](https://github.com/can1357/oh-my-pi/blob/v18.1.11/docs/memory.md),
[collaboration](https://github.com/can1357/oh-my-pi/blob/v18.1.11/docs/collab.md),
[extension compatibility](https://github.com/can1357/oh-my-pi/blob/v18.1.11/docs/extension-loading.md).

**Recommendation: experiment side-by-side; do not migrate production Gambit yet.**
OMP has legacy Pi import/manifest shims, but that does not prove task ownership,
`agent_settled`, abort/steering, worker CLI invocation, session replacement or your
custom footer behave equivalently. Its own workers, reviews and advisor loops also
compete with Gambit's policies. Separate `~/.omp` state and a pinned Nix input are
safer than sharing Pi config or silently replacing the `pi` binary.

An OMP trial should earn its complexity on one representative debugging/UI task
and one Gambit execution with abort/restart. Compare verified outcome, intervention
burden and cost—not feature count. Debugger + live supervision are the strongest
reasons to try it, not yet another planning mode.

## New capabilities tailored to your workflows

These are **integration ideas, not claims that an installable plugin already
implements them**:

1. **Gambit execution/attention panel.** Task/worktree ownership, actual provider +
   model + effort before dispatch, last useful artifact, and a decision/blocker/
   completion queue. Extend existing task/subagent state and cc-tools rather than
   introduce a competing database of truth. Surface bounded review/convergence.
2. **Local cross-harness evidence search.** Index Pi/Claude/Codex with role-aware
   citations, branch/session lineage and project exclusions. Produce a resume
   packet: decisions, artifacts, verification, unresolved questions. Pi-only Hermes
   search is a prototype, not fulfillment of this requirement.
3. **Tiltyard-style patch tournaments.** Several cheap isolated attempts on the
   same fixed task; tests filter first; a stronger model compares survivors; strict
   cost/time cap and preserved failures. Feed real results into Gambit's rung
   selection. This matches a workflow you have explicitly explored.
4. **Product-outcome briefings.** Combine existing analytics/error/request sources
   into a daily evidence-backed brief. Follow a shipped epic through to whether
   its promised user outcome improved; promote a finding into Gambit only when
   approved. No autonomous customer outreach or deployment.
5. **Research-to-visual workbench.** Cited hypotheses and reproducible analyses,
   bounded independent steelman, browser screenshots at multiple widths, generated
   visual assets and publication previews. Preserve your writing voice: outlines
   and evidence are not permission to write the actual prose for you.
6. **Mentat/fleet decision inbox.** Read-mostly runtime drift and project status,
   voice/mobile questions, approved intervention requests. Keep deployment/mail/
   purchase authority separate and preserve host-local build rules.

The common thread is better evidence and clearer human control—not more autonomous
activity for its own sake.
