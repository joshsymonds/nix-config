import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ProcessManager } from "../../../src/manager";

/** Only the explicitly loaded Orchestrator entry owns this gate. */
export function registerProcessKeepalive(
  pi: ExtensionAPI,
  manager: ProcessManager,
  cleanup: () => void,
) {
  let disposed = false;
  let turnWake = false;
  let failed = false;
  let scheduled = false;
  const waiters = new Set<() => void>();
  const release = () => {
    for (const resolve of waiters) resolve();
    waiters.clear();
  };
  const check = () => {
    if (disposed || turnWake || !manager.list().some(
      p => p.status === "running" || p.status === "terminating",
    )) release();
  };
  const changed = () => {
    if (disposed) {
      // A late close/stop can rearm the pinned manager's native watcher when
      // another record is terminate_timeout (still a native LIVE_STATUS).
      // Stop it AFTER that transition. This manager-local terminal listener
      // owns no external subscription/timer and is collected with the manager.
      queueMicrotask(() => manager.stopWatcher());
      return;
    }
    if (scheduled) return;
    scheduled = true;
    // NotificationService defers process_ended one microtask (including a
    // synchronous missing_pid during start). A prior process_started may
    // already have scheduled us: flush that deferred completion before list().
    queueMicrotask(() => queueMicrotask(() => {
      scheduled = false;
      check();
    }));
  };
  // Subscribe before ever examining ownership. No protocol/global ownership.
  manager.onEvent(changed);
  const originalKill = manager.kill;
  // terminate_timeout has no process_ended event. Observe the actual stop
  // promise, including command/RPC stops while agent_end is held. Do not
  // synthesize a notification: the native stop result owns timeout reporting.
  manager.kill = async (...args) => {
    try { return await originalKill.apply(manager, args); }
    finally { changed(); }
  };

  pi.on("turn_start", () => { turnWake = false; });
  pi.on("agent_end", async (event, ctx) => {
    const last = [...event.messages].reverse().find(m => m.role === "assistant");
    failed = last?.stopReason === "error" || last?.stopReason === "aborted";
    if (disposed) return;
    if (ctx.signal?.aborted) { cleanup(); return; }
    // Permit SDK retry/compaction. Only terminal failure is cleaned at settled.
    if (failed) return;
    const signal = ctx.signal;
    const abort = () => cleanup();
    signal?.addEventListener("abort", abort, { once: true });
    try {
      await new Promise<void>(resolve => {
        waiters.add(resolve);
        if (signal?.aborted) cleanup();
        else changed();
      });
    } finally {
      signal?.removeEventListener("abort", abort);
    }
  });
  pi.on("agent_settled", () => {
    // No holding here: the SDK has already removed ctx.signal. A timed-out
    // stop can leave a live OS process; reuse native force-kill/log cleanup.
    if (failed || manager.list().some(p => p.status === "terminate_timeout")) cleanup();
  });

  return {
    deliveredTurn() {
      if (disposed) return;
      // Called AFTER native sendMessage queued the wake, not on bus emission.
      // Keep it until turn_start so a wake before the hook cannot be lost.
      turnWake = true;
      release();
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      manager.kill = originalKill;
      release();
    },
  };
}
