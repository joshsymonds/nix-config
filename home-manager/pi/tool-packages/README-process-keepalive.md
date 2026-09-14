# Orchestrator process lifetime

The pinned pi-subagents runner completes a child when `session.prompt` resolves.
The pinned SDK awaits `agent_end` with its abort signal still active, then checks
queued messages and continues inside that same prompt. `agent_settled` is too
late to hold: its signal is gone.

The ordinary `@aliou/pi-processes` manifest and default factory remain
non-holding. Only `orchestrator-processes/index.ts` opts in. Its gate observes the
owned manager's events/list and actual stop promises. Native delivery calls the
gate **after** queueing a turn notification; the wake stays unconsumed until
`turn_start`. Context/ignore never create turns. Two microtask boundaries flush
the native deferred completion even if a start already scheduled a check.
Errored/aborted assistant endings bypass the hold for SDK retry handling;
terminal failure, abort, and shutdown reuse idempotent native resource cleanup.
A stop's `terminate_timeout` is finalized without `process_ended`; its actual
promise releases the gate, and settled cleanup kills remaining owned resources.
A manager-local terminal listener stops the native watcher after late close/stop
transitions, which otherwise can rearm it while a timeout record is retained;
it has no external subscription or timer and is collected with the manager.

## Loading into fresh children of an already-running root

Home Manager passes this absolute store entry to the rung generator:

```nix
"${workflowTools}/orchestrator-processes/index.ts"
# workflowTools = import ./tool-packages { inherit lib pkgs; };
```

Do not substitute the bare name `pi-processes` or a mutable home-directory path.
pi-subagents reloads agent definitions on dispatch, injects absolute extension
paths, and filters by canonical name. `orchestrator-processes` is unique, so the
old root entry is not retained. The small adjacent manifest declares the
`pi-processes` identity for the unchanged `ext:pi-processes` tool selector; it
adds no dependencies and is not a root-discovered package.

Filtering happens **after** discovery factories run, and the SDK checks duplicate
tools before that filter. The new entry therefore initializes at `session_start`
and uses the SDK's native private event bus. This avoids both discovery-time
tool conflicts and excluded old factories' still-subscribed bus listeners.
The installed subagent runner supports late registration and rederives tool
scope after binding. No runtime/controller changes, global environment flags,
role-text detection, polling, or synthetic model turns are involved.

## Bounded offline verification

From the repository root:

```sh
bash home-manager/pi/tool-packages/test-process-keepalive.sh --unpatched # RED, exit 1
bash home-manager/pi/tool-packages/test-process-keepalive.sh             # GREEN, 21 cases
bash home-manager/pi/tool-packages/test-process-keepalive.sh --typecheck # strict tsc
shellcheck home-manager/pi/tool-packages/test-process-keepalive.sh
```

The runner copies the pinned installed package into a temporary directory and
applies exactly the packaged patch/helper/entry. `PI_TEST_SDK` and
`PI_TEST_WORKFLOW_TOOLS` can select other installed paths. No package install is
needed; `--typecheck` uses the available `tsc` and temporary SDK-peer symlinks.

Tests use the actual notification service/delivery ordering and installed SDK,
scripted model responses with provider calls forbidden, and actual processes
controlled by stdin/exit events. A single event-loop checkpoint checks pending
promises without sleeps/polling. Cases include immediate and simultaneous exits,
before-hook and held readiness wakes, context/ignore, timeout, abort, failure and
retry, shutdown during delivery, sibling isolation, and ordinary root behavior.
SDK tests exercise the installed subagent path/selector functions with the old
installed entry still discoverable, then assert pending prompt, continuation,
final answer, prompt cancellation, child close, and log cleanup.

Full Nix build/check/activation and registry-resolved live model smoke are left
to the parent. These tests do not dispatch agents or spend model quota.
