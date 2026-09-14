import { createEventBus, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import processesExtension from "../node_modules/@aliou/pi-processes/extensions/processes/index";

export default function orchestratorProcesses(pi: ExtensionAPI) {
  // pi-subagents filters entries AFTER factories run. An excluded root
  // process factory can still have bus listeners; don't feed those listeners
  // our commands or notifications. All native process surfaces share this bus.
  const scoped = { ...pi, events: createEventBus() };
  let initialized = false;
  // The SDK checks duplicate tools before pi-subagents' path filter. Register
  // only once the selected entry is bound; pi-subagents supports late tools.
  pi.on("session_start", async () => {
    if (initialized) return;
    initialized = true;
    await processesExtension(scoped, true);
  });
}
