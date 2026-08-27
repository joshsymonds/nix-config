import assert from "node:assert/strict";
import test from "node:test";

import extension, { installFooter, statuslinePayload } from "./cc-tools.ts";

type ExecResult = {
	stdout: string;
	stderr: string;
	code: number;
	killed: boolean;
};

function assistant(cost: number, text = "answer") {
	return {
		type: "message",
		id: `assistant-${cost}`,
		message: {
			role: "assistant",
			content: [{ type: "text", text }],
			usage: { cost: { total: cost } },
		},
	};
}

function user(text = "question") {
	return {
		type: "message",
		id: `user-${text}`,
		message: { role: "user", content: [{ type: "text", text }] },
	};
}

function makeContext(overrides: Record<string, unknown> = {}) {
	const branch = [user(), assistant(0.25), assistant(0.5, "final answer")];
	return {
		mode: "tui",
		cwd: "/work/project",
		model: {
			id: "gpt-5.6",
			name: "GPT-5.6",
			provider: "openai-codex",
			contextWindow: 200_000,
		},
		thinkingLevel: "high",
		sessionManager: {
			getSessionId: () => "session-1",
			getLeafId: () => "leaf-1",
			getBranch: () => branch,
		},
		getContextUsage: () => ({
			tokens: 75_000,
			contextWindow: 200_000,
			percent: 37.5,
		}),
		...overrides,
	};
}

function deferred<T>() {
	let resolve!: (value: T) => void;
	let reject!: (error: Error) => void;
	const promise = new Promise<T>((resolvePromise, rejectPromise) => {
		resolve = resolvePromise;
		reject = rejectPromise;
	});
	return { promise, resolve, reject };
}

async function flush() {
	await new Promise<void>((resolve) => setImmediate(resolve));
	await new Promise<void>((resolve) => setImmediate(resolve));
}

function makeUIHarness() {
	let component:
		| {
				render(width: number): string[];
				dispose?(): void;
		  }
		| undefined;
	let branchChange: (() => void) | undefined;
	let renders = 0;

	const ui = {
		setFooter(factory: unknown) {
			component?.dispose?.();
			if (typeof factory !== "function") {
				component = undefined;
				return;
			}
			component = factory(
				{ requestRender: () => renders++ },
				{},
				{
					onBranchChange(callback: () => void) {
						branchChange = callback;
						return () => {
							branchChange = undefined;
						};
					},
				},
			);
		},
	};

	return {
		ui,
		component: () => component,
		branchChange: () => branchChange?.(),
		renders: () => renders,
	};
}

test("statuslinePayload maps live Pi state into the existing cc-tools schema", () => {
	const payload = JSON.parse(statuslinePayload(makeContext() as never, 120));

	assert.deepEqual(payload, {
		columns: 120,
		session_id: "session-1",
		model: {
			id: "gpt-5.6",
			provider: "openai-codex",
			display_name: "GPT-5.6",
		},
		cost: { total_cost_usd: 0.75 },
		context_window: {
			used_percentage: 37.5,
			context_window_size: 200_000,
		},
		workspace: {
			project_dir: "/work/project",
			current_dir: "/work/project",
			cwd: "/work/project",
		},
		cwd: "/work/project",
		effort: { level: "high" },
	});
});

test("footer renders cc-tools output and refreshes for width and branch changes", async () => {
	const harness = makeUIHarness();
	const calls: Array<{ command: string; args: string[]; options: unknown }> =
		[];
	const pi = {
		async exec(command: string, args: string[], options: unknown) {
			calls.push({ command, args, options });
			const width = JSON.parse(args[1]).columns;
			return {
				stdout: `statusline-${width}\n`,
				stderr: "",
				code: 0,
				killed: false,
			};
		},
	};
	const ctx = makeContext({ ui: harness.ui });

	const controller = installFooter(pi as never, ctx as never);
	assert.deepEqual(harness.component()?.render(100), [""]);
	await flush();

	assert.equal(calls[0].command, "cc-tools");
	assert.equal(calls[0].args[0], "statusline");
	assert.deepEqual(calls[0].options, { cwd: "/work/project", timeout: 5_000 });
	assert.deepEqual(harness.component()?.render(100), ["statusline-100"]);
	assert.equal(harness.renders(), 1);

	harness.component()?.render(80);
	await flush();
	assert.deepEqual(harness.component()?.render(80), ["statusline-80"]);

	harness.branchChange();
	await flush();
	assert.equal(calls.length, 3);

	controller.dispose();
	assert.equal(harness.component(), undefined);
});

test("footer coalesces updates and publishes only the newest result", async () => {
	const harness = makeUIHarness();
	const first = deferred<ExecResult>();
	const second = deferred<ExecResult>();
	const calls: string[] = [];
	const results = [first, second];
	const pi = {
		exec(_command: string, args: string[]) {
			calls.push(JSON.parse(args[1]).model.id);
			return results[calls.length - 1].promise;
		},
	};
	const firstCtx = makeContext({ ui: harness.ui });
	const controller = installFooter(pi as never, firstCtx as never);

	harness.component()?.render(100);
	controller.update(
		makeContext({
			ui: harness.ui,
			model: {
				id: "claude-opus-5",
				name: "Claude Opus 5",
				provider: "anthropic",
				contextWindow: 1_000_000,
			},
		}) as never,
	);
	assert.deepEqual(calls, ["gpt-5.6"]);

	first.resolve({ stdout: "stale\n", stderr: "", code: 0, killed: false });
	await flush();
	assert.deepEqual(calls, ["gpt-5.6", "claude-opus-5"]);

	second.resolve({ stdout: "current\n", stderr: "", code: 0, killed: false });
	await flush();
	assert.deepEqual(harness.component()?.render(100), ["current"]);
});

test("footer recovers after cc-tools execution rejects", async () => {
	const harness = makeUIHarness();
	let call = 0;
	const pi = {
		async exec() {
			call++;
			if (call === 2) throw new Error("spawn failed");
			return {
				stdout: call === 1 ? "first\n" : "recovered\n",
				stderr: "",
				code: 0,
				killed: false,
			};
		},
	};
	const ctx = makeContext({ ui: harness.ui });
	const controller = installFooter(pi as never, ctx as never);

	harness.component()?.render(100);
	await flush();
	assert.deepEqual(harness.component()?.render(100), ["first"]);

	controller.update(ctx as never);
	await flush();
	assert.deepEqual(harness.component()?.render(100), ["first"]);

	controller.update(ctx as never);
	await flush();
	assert.deepEqual(harness.component()?.render(100), ["recovered"]);
});

test("agent_settled refreshes the footer and sends the existing notify event", async () => {
	const harness = makeUIHarness();
	const handlers = new Map<string, (event: unknown, ctx: never) => void>();
	const calls: Array<{ command: string; args: string[] }> = [];
	const pi = {
		on(name: string, handler: (event: unknown, ctx: never) => void) {
			handlers.set(name, handler);
		},
		async exec(command: string, args: string[]) {
			calls.push({ command, args });
			return { stdout: "line\n", stderr: "", code: 0, killed: false };
		},
	};
	const ctx = makeContext({ ui: harness.ui });
	extension(pi as never);

	handlers.get("session_start")?.({}, ctx as never);
	harness.component()?.render(100);
	await flush();
	handlers.get("agent_settled")?.({}, ctx as never);
	await flush();

	const notify = calls.find(
		(call) => call.command === "cc-tools" && call.args[0] === "notify",
	);
	assert.ok(notify);
	assert.deepEqual(JSON.parse(notify.args[1]), {
		type: "agent-turn-complete",
		"thread-id": "session-1",
		"turn-id": "leaf-1",
		cwd: "/work/project",
		"input-messages": ["question"],
		"last-assistant-message": "final answer",
	});

	assert.ok(
		calls.filter((call) => call.args[0] === "statusline").length >= 2,
		"settled event should refresh the footer",
	);
});
