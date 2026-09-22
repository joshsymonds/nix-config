import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const stewardDirectory = dirname(fileURLToPath(import.meta.url));
const repository = resolve(stewardDirectory, "../..");

function commandRoot(command) {
  const executable = realpathSync(execFileSync("sh", ["-c", `command -v ${command}`], { encoding: "utf8" }).trim());
  return dirname(dirname(executable));
}

function nixPackageRoot(attribute) {
  return execFileSync("nix", ["eval", "--raw", `nixpkgs#${attribute}`], { encoding: "utf8" }).trim();
}

function evaluateCutover() {
  const output = execFileSync(
    "nix-instantiate",
    ["--eval", "--strict", "--json", resolve(stewardDirectory, "cutover-test.nix")],
    { cwd: repository, encoding: "utf8" },
  );
  return JSON.parse(output);
}

function withTemp(callback) {
  const directory = mkdtempSync(join(repository, ".steward-cutover-test-"));
  try {
    return callback(directory);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function executeServiceScript(serviceScript, expectedVariables) {
  withTemp((directory) => {
    const runtimeDirectory = join(directory, "runtime");
    const packageDirectory = join(directory, "steward-package");
    const pairedRuntime = join(directory, "steward-runtime");
    const marker = join(directory, "notifyd-executed");
    const escapedSentinel = join(directory, "shell-metacharacters-executed");
    mkdirSync(join(runtimeDirectory, "agenix"), { recursive: true });
    mkdirSync(join(packageDirectory, "bin"), { recursive: true });
    mkdirSync(join(pairedRuntime, "bin"), { recursive: true });
    writeFileSync(join(runtimeDirectory, "agenix/ntfy-url"), "synthetic-url");
    writeFileSync(join(runtimeDirectory, "agenix/ntfy-token"), "synthetic-token");
    writeFileSync(join(pairedRuntime, "bin/steward-pi-helper"), "fixture helper\n");
    const stewardExecutable = join(packageDirectory, "bin/steward");
    writeFileSync(stewardExecutable, `#!/bin/sh
set -eu
[ "$#" -eq 1 ]
[ "$1" = notifyd ]
[ "$STEWARD_NTFY_URL" = "$EXPECTED_NTFY_URL" ]
[ "$STEWARD_NTFY_TOKEN" = "$EXPECTED_NTFY_TOKEN" ]
[ "$STEWARD_HELPER_BIN" = "$EXPECTED_HELPER_BIN" ]
[ "$STEWARD_MODEL_PROVIDER" = "$EXPECTED_MODEL_PROVIDER" ]
[ "$STEWARD_MODEL_ID" = "$EXPECTED_MODEL_ID" ]
[ "$STEWARD_MODEL_THINKING" = "$EXPECTED_MODEL_THINKING" ]
printf passed > "$EXPECTED_MARKER"
`);
    chmodSync(stewardExecutable, 0o755);

    const replaceMarkers = (value) => value
      .replaceAll("@STEWARD_RUNTIME@", pairedRuntime)
      .replaceAll("@SHELL_SENTINEL@", escapedSentinel);
    const script = replaceMarkers(serviceScript)
      .replaceAll("@STEWARD_PACKAGE@", packageDirectory);
    const result = spawnSync("bash", ["-c", script], {
      encoding: "utf8",
      env: {
        ...process.env,
        XDG_RUNTIME_DIR: runtimeDirectory,
        EXPECTED_MARKER: marker,
        EXPECTED_NTFY_URL: "synthetic-url",
        EXPECTED_NTFY_TOKEN: "synthetic-token",
        EXPECTED_HELPER_BIN: replaceMarkers(expectedVariables.STEWARD_HELPER_BIN),
        EXPECTED_MODEL_PROVIDER: replaceMarkers(expectedVariables.STEWARD_MODEL_PROVIDER),
        EXPECTED_MODEL_ID: replaceMarkers(expectedVariables.STEWARD_MODEL_ID),
        EXPECTED_MODEL_THINKING: replaceMarkers(expectedVariables.STEWARD_MODEL_THINKING),
      },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(marker, "utf8"), "passed");
    assert.equal(statSync(escapedSentinel, { throwIfNoEntry: false }), undefined);
  });
}

test("flake pins the canonical Steward repository and actual locked implementation SHA", () => {
  const flake = readFileSync(resolve(repository, "flake.nix"), "utf8");
  const lock = JSON.parse(readFileSync(resolve(repository, "flake.lock"), "utf8"));
  assert.match(
    flake,
    /steward\.url = "github:joshsymonds\/steward\/3516f7989d768a9045b0fab9dee8ef08a798fcd0";/,
  );
  assert.equal(lock.nodes.root.inputs.steward, "steward");
  assert.deepEqual(
    {
      owner: lock.nodes.steward.locked.owner,
      repo: lock.nodes.steward.locked.repo,
      rev: lock.nodes.steward.locked.rev,
      type: lock.nodes.steward.locked.type,
    },
    {
      owner: "joshsymonds",
      repo: "steward",
      rev: "3516f7989d768a9045b0fab9dee8ef08a798fcd0",
      type: "github",
    },
  );
});

test("evaluated shared module is the one package, secret-file environment, and notifyd owner", () => {
  const evaluated = evaluateCutover();
  const shared = evaluated.steward;
  assert.ok(shared.imports.some((path) => path.endsWith("/home-manager/steward")));
  assert.deepEqual(shared.packages, ["@STEWARD_PACKAGE@"]);
  assert.deepEqual(shared.secretNames, ["ntfy-token", "ntfy-url"]);
  assert.ok(shared.secretFiles["ntfy-url"].endsWith("/secrets/user/ntfy-url.age"));
  assert.ok(shared.secretFiles["ntfy-token"].endsWith("/secrets/user/ntfy-token.age"));
  assert.deepEqual(shared.serviceNames, ["steward-notifyd"]);
  assert.deepEqual(shared.activationNames, []);
  assert.deepEqual(shared.sessionVariables, {
    PATCHBAY_CALLER_KEY_FILE: "/run/agenix/patchbay-caller-key",
    STEWARD_HELPER_BIN: "@STEWARD_RUNTIME@/bin/steward-pi-helper",
    STEWARD_MODEL_ID: "gpt-6-luna",
    STEWARD_MODEL_PROVIDER: "openai-codex",
    STEWARD_MODEL_THINKING: "medium",
    STEWARD_NTFY_TOKEN_FILE: "${XDG_RUNTIME_DIR}/agenix/ntfy-token",
    STEWARD_NTFY_URL_FILE: "${XDG_RUNTIME_DIR}/agenix/ntfy-url",
    STEWARD_PATCHBAY_URL: "http://127.0.0.1:4242",
    STEWARD_STATE_FILE: "/home/tester/.cache/steward/state.json",
  });
  assert.match(shared.serviceScript, /STEWARD_NTFY_URL=.*cat/);
  assert.match(shared.serviceScript, /export STEWARD_NTFY_URL STEWARD_NTFY_TOKEN/);
  assert.match(shared.serviceScript, /cat "\$\{XDG_RUNTIME_DIR\}\/agenix\/ntfy-url"/);
  assert.match(shared.serviceScript, /STEWARD_NTFY_TOKEN=.*cat/);
  assert.match(shared.serviceScript, /exec @STEWARD_PACKAGE@\/bin\/steward notifyd/);
  assert.equal(shared.service.Service.Restart, "on-failure");
  assert.doesNotMatch(shared.service.Service.Environment.join("\n"), /claude|codex/i);
  executeServiceScript(shared.serviceScript, shared.sessionVariables);
});

test("notifyd executes with effective metacharacter and empty-string overrides", () => {
  const shared = evaluateCutover().stewardOverride;
  assert.deepEqual(shared.sessionVariables, {
    PATCHBAY_CALLER_KEY_FILE: "/run/agenix/patchbay-caller-key",
    STEWARD_HELPER_BIN: "helper ' $(touch @SHELL_SENTINEL@) ;",
    STEWARD_MODEL_ID: "model \"$HOME\"; false",
    STEWARD_MODEL_PROVIDER: "",
    STEWARD_MODEL_THINKING: "",
    STEWARD_NTFY_TOKEN_FILE: "${XDG_RUNTIME_DIR}/agenix/ntfy-token",
    STEWARD_NTFY_URL_FILE: "${XDG_RUNTIME_DIR}/agenix/ntfy-url",
    STEWARD_PATCHBAY_URL: "http://127.0.0.1:4242",
    STEWARD_STATE_FILE: "/home/tester/.cache/steward/state.json",
  });
  executeServiceScript(shared.serviceScript, shared.sessionVariables);
});

test("Claude has direct native root Stop, input, cleanup, and statusline wiring", () => {
  const actual = JSON.parse(readFileSync(resolve(repository, "home-manager/claude-code/settings.json"), "utf8"));
  assert.deepEqual(actual.statusLine, {
    type: "command",
    command: "steward-statusline",
    padding: 0,
    refreshInterval: 5,
  });
  assert.deepEqual(actual.subagentStatusLine, {
    type: "command",
    command: "steward subagent-statusline",
  });
  assert.deepEqual(actual.hooks.Stop, [{
    matcher: "",
    hooks: [
      { type: "command", command: "~/.claude/hooks/usage-summary-refresh.sh" },
      { type: "command", command: "steward notify --harness claude-code", timeout: 90 },
    ],
  }]);
  assert.deepEqual(actual.hooks.Notification, [{
    matcher: "permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog",
    hooks: [
      { type: "command", command: "steward notify --harness claude-code", timeout: 90 },
    ],
  }]);
  assert.deepEqual(actual.hooks.SessionEnd, [{
    matcher: "",
    hooks: [{ type: "command", command: "steward notify --harness claude-code" }],
  }]);
  assert.ok(!("SubagentStop" in actual.hooks));

  assert.equal(actual.model, "chatgpt/astra");
  assert.equal(actual.effortLevel, "xhigh");
});

test("AWS profile mirror follows Steward's canonical state-file contract atomically", () => {
  withTemp((directory) => {
    const script = resolve(repository, "home-manager/claude-code/hooks/aws-profile-mirror.sh");
    const state = join(directory, "xdg-cache/steward/state.json");
    const env = { ...process.env, HOME: directory, STEWARD_STATE_FILE: state };
    execFileSync(script, [], {
      env,
      input: JSON.stringify({ tool_input: { command: "export AWS_PROFILE=production" } }),
    });
    assert.deepEqual(JSON.parse(readFileSync(state, "utf8")), { aws_profile: "production" });
    assert.equal(statSync(state).isFile(), true);
    assert.equal(lstatSync(join(directory, "xdg-cache/steward")).isDirectory(), true);
  });
});

test("evaluated current Pi config preserves tools and uses one paired Steward graph", () => {
  const pi = evaluateCutover().pi;
  assert.equal(pi.package, "@STEWARD_PACKAGE@");
  assert.deepEqual(pi.packages, [
    "/nix/store/fixture-pi-tasks-0.9.0",
    "@STEWARD_EXTENSION_ROOT@",
    "/nix/store/fixture-pi-goal-0.54.3",
    "/nix/store/fixture-pi-lsp-0.49.7",
    { source: "/nix/store/fixture-pi-workflow-tools/node_modules/@aliou/pi-processes", prompts: [], themes: [] },
    { source: "/nix/store/fixture-pi-workflow-tools/node_modules/pi-web-access", skills: [], prompts: [], themes: [] },
    { source: "/nix/store/fixture-pi-agent-browser-native-0.6.6", skills: [], prompts: [], themes: [] },
  ]);
  assert.deepEqual(Object.keys(pi.lsp.servers).sort(), ["gopls", "nixd", "pyright", "typescript"]);
  assert.equal(pi.lsp.servers.typescript.initialization.tsserver.path, "/nix/store/fixture-typescript/lib/node_modules/typescript/lib/tsserver.js");
  assert.equal(pi.homeFileNames.includes(".pi/agent/extensions/cc-tools.ts"), false);
  assert.ok(pi.homeFileNames.includes(".pi/agent/extensions/processes.json"));
  assert.equal(pi.browserCli, "/nix/store/fixture-agent-browser/bin/agent-browser");
  assert.equal(pi.agents, "/nix/store/fixture-pi-gambit-rung-agents");
  assert.equal(pi.context, readFileSync(resolve(repository, "home-manager/pi/AGENTS.md"), "utf8"));
  assert.deepEqual(pi.browser, {
    version: 1,
    webSearch: { enabled: false },
    browser: { executablePath: "/nix/store/fixture-chromium/bin/chromium" },
  });
  assert.deepEqual(pi.processes, {
    version: "0.10.6",
    execution: { shellPath: "/nix/store/fixture-bash/bin/bash" },
    interception: { blockBackgroundCommands: false },
    widget: { showStatusWidget: false, dockDefaultState: "closed" },
  });
  assert.deepEqual(
    [pi.defaultProvider, pi.defaultModel, pi.defaultThinkingLevel],
    ["openai-codex", "gpt-6-astra", "high"],
  );
  assert.equal(pi.models.providers["openai-codex"].models[0].id, "gpt-6-astra");
  assert.deepEqual(pi.tasks, { taskScope: "session-global", autoCascade: false, autoClearCompleted: "never" });
  assert.deepEqual(pi.goal, { rpc: { enabled: false }, continuationLimits: { automaticTurns: null, noProgressTurns: null } });
  assert.match(pi.goalTypebox, /@STEWARD_NODE_MODULES@\/typebox/);
  assert.deepEqual(pi.subagents, {
    backgroundByDefault: true,
    widgetMode: "all",
    strictAgentFiles: true,
    fallbackSubagent: "none",
    workflowsEnabled: false,
    schedulingEnabled: false,
  });
});

test("generated Codex baseline has no Steward integration and retains native approvals", () => {
  const managed = evaluateCutover().codex.managed;
  assert.doesNotMatch(managed, /steward|hooks\.Stop|trusted_hash|\bnotify\s*=/i);
  assert.match(managed, /approval_policy = "never"/);
  assert.match(managed, /sandbox_mode = "danger-full-access"/);
  assert.match(managed, /notifications = \["approval-requested"\]/);
});

test("configured Claude timeout permits bounded inline delivery retry", async (t) => {
  const stewardBin = process.env.STEWARD_TEST_BIN;
  if (!stewardBin) {
    t.skip("STEWARD_TEST_BIN is required for the package-dependent fallback regression");
    return;
  }

  const settings = JSON.parse(readFileSync(resolve(repository, "home-manager/claude-code/settings.json"), "utf8"));
  const handler = settings.hooks.Stop[0].hooks.find((hook) => hook.command === "steward notify --harness claude-code");
  assert.ok(handler, "Claude settings must contain the synchronous native Stop handler");
  assert.equal(handler.timeout, 90);
  const hookTimeoutMs = handler.timeout * 1_000;
  const expectedBody = "synthetic bounded retry body";
  const payload = {
    session_id: "synthetic-session",
    cwd: "/tmp/synthetic-project",
    hook_event_name: "Stop",
    last_assistant_message: expectedBody,
  };
  const requests = [];
  const responseTimers = new Set();
  const server = createServer((request, response) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      requests.push({ body, hasAuthorization: request.headers.authorization !== undefined });
      const timer = setTimeout(() => {
        responseTimers.delete(timer);
        response.statusCode = requests.length === 1 ? 503 : 200;
        response.end();
      }, 4_600);
      responseTimers.add(timer);
    });
  });
  const root = mkdtempSync(join(tmpdir(), "steward-fallback-"));
  let child;
  let childTimer;
  const safetyTimer = setTimeout(() => {
    child?.kill("SIGKILL");
    server.closeAllConnections();
  }, 20_000);
  try {
    await new Promise((resolveListen, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolveListen);
    });
    const { port } = server.address();
    const binDirectory = dirname(stewardBin);
    child = spawn(stewardBin, ["notify", "--harness", "claude-code"], {
      env: {
        HOME: join(root, "home"),
        PATH: binDirectory,
        STEWARD_NTFY_URL: `http://127.0.0.1:${port}/synthetic-topic`,
        XDG_CACHE_HOME: join(root, "cache"),
        XDG_CONFIG_HOME: join(root, "config"),
        XDG_RUNTIME_DIR: join(root, "runtime"),
        XDG_STATE_HOME: join(root, "state"),
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const started = Date.now();
    child.stdin.end(`${JSON.stringify(payload)}\n`);
    const result = await new Promise((resolveExit, reject) => {
      child.once("error", reject);
      child.once("exit", (code, signal) => resolveExit({ code, signal }));
      childTimer = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error(`Steward exceeded configured ${hookTimeoutMs}ms Claude Stop timeout`));
      }, hookTimeoutMs);
    });
    const elapsed = Date.now() - started;
    assert.deepEqual(result, { code: 0, signal: null }, stderr);
    assert.equal(requests.length, 2);
    assert.deepEqual(requests.map(({ body }) => body), [expectedBody, expectedBody]);
    assert.deepEqual(requests.map(({ hasAuthorization }) => hasAuthorization), [false, false]);
    assert.ok(elapsed > 10_000, `retry completed too quickly: ${elapsed}ms`);
    assert.ok(elapsed < 11_000, `retry exceeded the Sender bound: ${elapsed}ms`);
    assert.ok(elapsed < hookTimeoutMs, `retry exceeded configured hook timeout: ${elapsed}ms`);
  } finally {
    clearTimeout(childTimer);
    clearTimeout(safetyTimer);
    child?.kill("SIGKILL");
    for (const timer of responseTimers) clearTimeout(timer);
    server.closeAllConnections();
    await new Promise((resolveClose) => server.close(resolveClose));
    rmSync(root, { recursive: true, force: true });
  }
});

test("generated Codex activation preserves unrelated mutable configuration atomically", () => {
  const evaluated = evaluateCutover();
  withTemp((directory) => {
    const baseline = join(directory, "managed.toml");
    writeFileSync(baseline, evaluated.codex.managed);
    const replacements = new Map([
      ["@BASE@", baseline],
      ["@COREUTILS@", commandRoot("mktemp")],
      ["@JQ@", commandRoot("jq")],
      ["@YQ@", nixPackageRoot("yq-go")],
    ]);
    let activation = evaluated.codex.activation;
    for (const [marker, value] of replacements) {
      activation = activation.replaceAll(marker, value);
    }
    const home = join(directory, "home");
    const target = join(home, ".codex/config.toml");
    mkdirSync(dirname(target), { recursive: true });
    const current = {
      model: "user-model",
      approval_policy: "on-request",
      custom: { nested: { value: "keep" } },
      hooks: {
        Stop: [{ matcher: "all", hooks: [{ type: "command", command: "/opt/user/hook" }] }],
        state: { "/work/user:stop:0:0": { enabled: true, trusted_hash: "sha256:user", customvalue: "keep" } },
      },
      projects: { "/work/user": { trust_level: "trusted", customnested: { value: "keep" } } },
      tui: { notifications: ["user-event"] },
    };
    const yq = join(nixPackageRoot("yq-go"), "bin/yq");
    writeFileSync(target, execFileSync(yq, ["-p=json", "-o=toml", "."], {
      input: JSON.stringify(current), encoding: "utf8",
    }));
    chmodSync(target, 0o600);
    const env = { HOME: home };
    const first = spawnSync("bash", ["-c", activation], { env, encoding: "utf8" });
    assert.equal(first.status, 0, first.stderr);
    const actual = JSON.parse(execFileSync(yq, ["-p=toml", "-o=json", ".", target], { encoding: "utf8" }));
    assert.deepEqual(actual.hooks, current.hooks);
    assert.deepEqual(actual.projects, {
      ...current.projects,
      "/home/joshsymonds/nix-config": { trust_level: "trusted" },
    });
    assert.deepEqual(actual.custom, current.custom);
    assert.equal(actual.model, "gpt-6-sol");
    assert.equal(actual.approval_policy, "never");
    assert.equal(actual.tui.notifications[0], "approval-requested");
    assert.equal(statSync(target).mode & 0o777, 0o600);
    const firstContents = readFileSync(target, "utf8");
    const firstInode = statSync(target).ino;
    const second = spawnSync("bash", ["-c", activation], { env, encoding: "utf8" });
    assert.equal(second.status, 0, second.stderr);
    assert.equal(readFileSync(target, "utf8"), firstContents);
    assert.equal(statSync(target).ino, firstInode, "idempotent activation rewrote the target");

    const discardingActivation = activation.replace("'.[0] * .[1]'", "'.[1]'");
    writeFileSync(target, execFileSync(yq, ["-p=json", "-o=toml", "."], {
      input: JSON.stringify(current), encoding: "utf8",
    }));
    const discarded = spawnSync("bash", ["-c", discardingActivation], { env, encoding: "utf8" });
    assert.equal(discarded.status, 0, discarded.stderr);
    const discardedJson = JSON.parse(execFileSync(yq, ["-p=toml", "-o=json", ".", target], { encoding: "utf8" }));
    assert.equal(discardedJson.hooks, undefined, "negative control must discard mutable hook state");
    assert.equal(discardedJson.projects["/work/user"], undefined, "negative control must discard user project state");

    writeFileSync(target, "invalid = [\n");
    chmodSync(target, 0o640);
    const before = readFileSync(target);
    const failed = spawnSync("bash", ["-c", activation], { env, encoding: "utf8" });
    assert.notEqual(failed.status, 0);
    assert.deepEqual(readFileSync(target), before);
    assert.equal(statSync(target).mode & 0o777, 0o640);
  });
});

test("cutover gate has no checkout-local Git object dependency", () => {
  const source = readFileSync(resolve(stewardDirectory, "cutover.test.mjs"), "utf8");
  for (const forbidden of [
    `baseline${"Tree"}`,
    `baseline${"File"}`,
    `execFileSync("${"git"}", ["show"`,
  ]) {
    assert.equal(source.includes(forbidden), false, `checkout-local dependency: ${forbidden}`);
  }
});

test("all consumer profiles delegate removed-unit retirement to Home Manager sd-switch", () => {
  for (const profile of [
    "home-manager/desktop-x86_64-linux.nix",
    "home-manager/headless-x86_64-linux.nix",
    "home-manager/minimal.nix",
  ]) {
    const source = readFileSync(resolve(repository, profile), "utf8");
    assert.match(source, /systemd\.user\.startServices = "sd-switch";/, profile);
  }
  assert.deepEqual(evaluateCutover().steward.serviceNames, ["steward-notifyd"]);
});

test("cutover documentation gives current-main validation and the deployment retirement check", () => {
  const documentation = readFileSync(resolve(repository, "docs/steward-cutover.md"), "utf8");
  assert.match(documentation, /STEWARD_TEST_BIN=.*node --test home-manager\/steward\/cutover\.test\.mjs/);
  assert.doesNotMatch(documentation, /STEWARD_TEST_USER_OVERLAY|overlay replay|separate user deployment overlay/i);
  assert.match(documentation, /deployed user commit 2b1a0eeb85461bccbc42808c94a666eef07aa127/i);
  assert.match(documentation, /sd-switch/);
  assert.match(documentation, /cc-tools-notifyd.*inactive/is);
  assert.match(documentation, /steward-notifyd.*active/is);
});

test("active notification documentation matches current Steward wiring and identity", () => {
  const hooks = readFileSync(resolve(repository, "home-manager/claude-code/hooks/README.md"), "utf8");
  const remote = readFileSync(resolve(repository, "docs/claude-remote-setup.md"), "utf8");
  const devspaces = readFileSync(resolve(repository, "docs/devspaces.md"), "utf8");
  const active = [hooks, remote, devspaces].join("\n");

  assert.match(hooks, /github\.com\/joshsymonds\/steward/);
  assert.match(hooks, /steward notify --harness claude-code/);
  assert.match(hooks, /permission_prompt\|agent_needs_input\|elicitation_dialog\|elicitation_url_dialog/);
  assert.match(hooks, /SessionEnd.*cleanup/is);
  assert.match(hooks, /usage-summary-refresh\.sh/);
  assert.match(hooks, /Pi.*root TUI.*agent_settled/is);
  assert.match(hooks, /no Codex integration/i);
  assert.match(hooks, /STEWARD_NTFY_URL_FILE.*STEWARD_NTFY_TOKEN_FILE/s);
  assert.match(hooks, /\$\{XDG_STATE_HOME:-~\/\.local\/state\}\/steward\/notify\/notify-decisions\.jsonl/);
  assert.match(hooks, /in-memory claims/i);
  assert.match(hooks, /current-hook fallback/i);
  assert.match(hooks, /no judge, watchdog, or task-pending gate/i);

  for (const contextDoc of [remote, devspaces]) {
    assert.match(contextDoc, /steward notify --harness claude-code/);
    assert.match(contextDoc, /TMUX_PANE/);
    assert.match(contextDoc, /session_name:window_index/);
    assert.match(contextDoc, /label\/project.*hostname fallback/is);
    assert.doesNotMatch(contextDoc, /notifications?.*(?:read|consume|derive).*(?:DEV_CONTEXT|DEV_CONTEXT_ICON)/i);
  }

  assert.doesNotMatch(active, /cc-tools notify|CC_TOOLS_NTFY_|Haiku judge|detached watchdog|background tasks are pending|Codex wires/i);
});

test("active consumer files contain no old package, service, socket, env, or runtime alias", () => {
  const paths = [
    "flake.nix",
    "home-manager/common.nix",
    "home-manager/steward/default.nix",
    "home-manager/claude-code/default.nix",
    "home-manager/claude-code/settings.json",
    "home-manager/pi/default.nix",
    "home-manager/codex/default.nix",
    "home-manager/codex/managed-config.nix",
    "home-manager/hosts/shrike.nix",
    "home-manager/starship/default.nix",
  ];
  const active = paths.map((path) => readFileSync(resolve(repository, path), "utf8")).join("\n");
  assert.doesNotMatch(active, /inputs\.cc-tools|CC_TOOLS_|\.claude\/bin\/cc-tools|systemd\.user\.services\.cc-tools-notifyd/);
  assert.doesNotMatch(active, /SubagentStop|STEWARD_SOCKET/);
  assert.doesNotMatch(active, /gambitHasCodex|plugins\/gambit|gambit@personal/);
  assert.match(readFileSync(resolve(repository, "home-manager/statusline-aliases/default.nix"), "utf8"), /steward resolve/);
  assert.match(readFileSync(resolve(repository, "home-manager/starship/default.nix"), "utf8"), /steward render-clouds/);
  assert.match(readFileSync(resolve(repository, "home-manager/hosts/shrike.nix"), "utf8"), /inputs\.steward\.packages/);
});
