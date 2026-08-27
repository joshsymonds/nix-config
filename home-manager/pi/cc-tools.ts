import type { AssistantMessage } from "@earendil-works/pi-ai";
import type {
	ExtensionAPI,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";

interface FooterController {
	update(ctx: ExtensionContext): void;
	dispose(): void;
}

function sessionCost(ctx: ExtensionContext): number {
	let total = 0;
	for (const entry of ctx.sessionManager.getBranch()) {
		if (entry.type === "message" && entry.message.role === "assistant") {
			total += (entry.message as AssistantMessage).usage.cost.total;
		}
	}
	return total;
}

export function statuslinePayload(
	ctx: ExtensionContext,
	columns: number,
): string {
	const model = ctx.model;
	const context = ctx.getContextUsage();

	return JSON.stringify({
		columns,
		session_id: ctx.sessionManager.getSessionId(),
		model: {
			id: model?.id ?? "pi",
			provider: model?.provider ?? "",
			display_name: model?.name ?? model?.id ?? "Pi",
		},
		cost: { total_cost_usd: sessionCost(ctx) },
		context_window: {
			used_percentage: context?.percent ?? 0,
			context_window_size: context?.contextWindow ?? model?.contextWindow ?? 0,
		},
		workspace: {
			project_dir: ctx.cwd,
			current_dir: ctx.cwd,
			cwd: ctx.cwd,
		},
		cwd: ctx.cwd,
		effort: ctx.thinkingLevel ? { level: ctx.thinkingLevel } : undefined,
	});
}

export function installFooter(
	pi: ExtensionAPI,
	initialCtx: ExtensionContext,
): FooterController {
	let ctx = initialCtx;
	let columns = 0;
	let line = "";
	let dirty = true;
	let running = false;
	let disposed = false;
	let requestRender: (() => void) | undefined;

	const refresh = async () => {
		if (disposed || running || columns <= 0) return;

		running = true;
		try {
			do {
				dirty = false;
				const refreshCtx = ctx;
				const refreshColumns = columns;
				try {
					const result = await pi.exec(
						"cc-tools",
						["statusline", statuslinePayload(refreshCtx, refreshColumns)],
						{ cwd: refreshCtx.cwd, timeout: 5_000 },
					);

					if (!disposed && result.code === 0 && result.stdout) {
						line = result.stdout.replace(/[\r\n]+$/, "");
					}
				} catch {
					// Keep the last good line. A later lifecycle event retries.
				}
			} while (!disposed && dirty);
		} finally {
			running = false;
			requestRender?.();
		}
	};

	initialCtx.ui.setFooter((tui, _theme, footerData) => {
		requestRender = () => tui.requestRender();
		const unsubscribe = footerData.onBranchChange(() => {
			dirty = true;
			void refresh();
		});

		return {
			render(width: number): string[] {
				if (width !== columns) {
					columns = width;
					dirty = true;
					void refresh();
				}
				return line ? [line] : [""];
			},
			invalidate() {},
			dispose() {
				disposed = true;
				unsubscribe();
			},
		};
	});

	return {
		update(nextCtx: ExtensionContext) {
			ctx = nextCtx;
			dirty = true;
			void refresh();
		},
		dispose() {
			disposed = true;
			initialCtx.ui.setFooter(undefined);
		},
	};
}

function messageText(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";

	return content
		.filter(
			(block): block is { type: "text"; text: string } =>
				typeof block === "object" &&
				block !== null &&
				"type" in block &&
				block.type === "text" &&
				"text" in block &&
				typeof block.text === "string",
		)
		.map((block) => block.text)
		.join("\n");
}

export default function (pi: ExtensionAPI) {
	let footer: FooterController | undefined;

	pi.on("session_start", (_event, ctx) => {
		if (ctx.mode !== "tui") return;
		footer?.dispose();
		footer = installFooter(pi, ctx);
	});

	pi.on("session_shutdown", () => {
		footer?.dispose();
		footer = undefined;
	});

	pi.on("agent_start", (_event, ctx) => footer?.update(ctx));
	pi.on("turn_end", (_event, ctx) => footer?.update(ctx));
	pi.on("tool_execution_end", (_event, ctx) => footer?.update(ctx));
	pi.on("model_select", (_event, ctx) => footer?.update(ctx));
	pi.on("thinking_level_select", (_event, ctx) => footer?.update(ctx));
	pi.on("session_compact", (_event, ctx) => footer?.update(ctx));
	pi.on("session_tree", (_event, ctx) => footer?.update(ctx));

	pi.on("agent_settled", (_event, ctx) => {
		if (ctx.mode !== "tui") return;
		footer?.update(ctx);

		let lastUserMessage = "";
		let lastAssistantMessage = "";
		const branch = ctx.sessionManager.getBranch();

		for (let i = branch.length - 1; i >= 0; i--) {
			const entry = branch[i];
			if (entry.type !== "message") continue;

			if (!lastAssistantMessage && entry.message.role === "assistant") {
				lastAssistantMessage = messageText(entry.message.content);
			} else if (!lastUserMessage && entry.message.role === "user") {
				lastUserMessage = messageText(entry.message.content);
			}

			if (lastUserMessage && lastAssistantMessage) break;
		}

		const payload = JSON.stringify({
			type: "agent-turn-complete",
			"thread-id": ctx.sessionManager.getSessionId(),
			"turn-id": ctx.sessionManager.getLeafId() ?? "settled",
			cwd: ctx.cwd,
			"input-messages": lastUserMessage ? [lastUserMessage] : [],
			"last-assistant-message": lastAssistantMessage,
		});

		void pi.exec("cc-tools", ["notify", payload], {
			cwd: ctx.cwd,
			timeout: 90_000,
		});
	});
}
