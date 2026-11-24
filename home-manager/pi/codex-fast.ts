// The Codex fast tier for the fast role agents on Pi.
//
// Loaded only by the Pi rung agents whose patchbay twin Seat carries
// speed = "fast" (home-manager/claude-code/role-agents.nix lists the
// extension in their frontmatter): every request such a session sends to the
// openai-codex provider asks for the priority service tier, which the Codex
// catalogue calls Fast — 1.5x speed at roughly 2.5x quota. Pi's Codex provider
// forwards service_tier on its Responses websocket transport, the one
// transport the backend honors the tier on. Nothing here inspects the model:
// the agent file that loads this extension is the decision that the session
// is a fast rung.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const CODEX_PROVIDER = "openai-codex";
const FAST_TIER = "priority";

export default function codexFast(pi: ExtensionAPI): void {
  pi.on("before_provider_request", (event, ctx) => {
    if (ctx.model?.provider !== CODEX_PROVIDER) {
      return undefined;
    }
    const payload = event.payload;
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
      return undefined;
    }
    return { ...(payload as Record<string, unknown>), service_tier: FAST_TIER };
  });
}
