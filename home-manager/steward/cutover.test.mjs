import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const stewardDirectory = dirname(fileURLToPath(import.meta.url));
const repository = resolve(stewardDirectory, "../..");
const helper = resolve(repository, "home-manager/codex/merge-config.py");
const canonicalCommand = "/nix/store/new-steward/bin/steward notify --harness codex";
const requireUserOverlay = process.env.STEWARD_TEST_USER_OVERLAY === "1";

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

function invokeMerge(baseline, current, target = "/home/tester/.codex/config.toml") {
  return withTemp((directory) => {
    const baselinePath = join(directory, "baseline.json");
    const currentPath = join(directory, "current.json");
    writeFileSync(baselinePath, JSON.stringify(baseline));
    writeFileSync(currentPath, JSON.stringify(current));
    const result = spawnSync(
      "python3",
      [helper, "--baseline", baselinePath, "--current", currentPath, "--target", target],
      { encoding: "utf8" },
    );
    return {
      ...result,
      json: result.status === 0 ? JSON.parse(result.stdout) : undefined,
    };
  });
}

function desiredBaseline(command = canonicalCommand) {
  return {
    model: "gpt-5.6-sol",
    approval_policy: "never",
    sandbox_mode: "danger-full-access",
    hooks: {
      Stop: [
        {
          hooks: [
            { type: "command", command, timeout: 10, async: false },
          ],
        },
      ],
    },
    tui: { notifications: ["approval-requested"] },
  };
}

function stateKey(target, group, handler) {
  return `${target}:stop:${group}:${handler}`;
}

function ownHandler(command = canonicalCommand) {
  return { type: "command", command, timeout: 10, async: false };
}

function expectedHash(command) {
  const normalized = JSON.stringify({
    event_name: "stop",
    hooks: [{ async: false, command, timeout: 10, type: "command" }],
  });
  return `sha256:${execFileSync("sha256sum", { input: normalized, encoding: "utf8" }).split(" ")[0]}`;
}

test("flake pins the canonical Steward repository and actual locked implementation SHA", () => {
  const flake = readFileSync(resolve(repository, "flake.nix"), "utf8");
  const lock = JSON.parse(readFileSync(resolve(repository, "flake.lock"), "utf8"));
  assert.match(
    flake,
    /steward\.url = "github:joshsymonds\/steward\/bb73759898e69e61d993790d4ac5721ef3c2dd15";/,
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
      rev: "bb73759898e69e61d993790d4ac5721ef3c2dd15",
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
    STEWARD_MODEL_ID: "gpt-5.6-luna",
    STEWARD_MODEL_PROVIDER: "openai-codex",
    STEWARD_MODEL_THINKING: "low",
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
    matcher: "permission_prompt|agent_needs_input",
    hooks: [
      { type: "command", command: "steward notify --harness claude-code", timeout: 90 },
    ],
  }]);
  assert.deepEqual(actual.hooks.SessionEnd, [{
    matcher: "",
    hooks: [{ type: "command", command: "steward notify --harness claude-code" }],
  }]);
  assert.ok(!("SubagentStop" in actual.hooks));

  if (requireUserOverlay) {
    assert.equal(actual.model, "chatgpt/astra");
    assert.equal(actual.effortLevel, "xhigh");
  }
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

test("evaluated Pi config uses one paired Steward graph and validates optional LSP as a consistent overlay", () => {
  const pi = evaluateCutover().pi;
  const committedPackages = [
    "/nix/store/fixture-pi-tasks-0.9.0",
    "@STEWARD_EXTENSION_ROOT@",
    "/nix/store/fixture-pi-goal-0.54.3",
  ];
  const lspPackage = "/nix/store/fixture-pi-lsp-0.49.7";
  const hasLspPackage = pi.packages.includes(lspPackage);
  const hasLspMap = pi.lsp !== null;

  assert.equal(pi.package, "@STEWARD_PACKAGE@");
  assert.deepEqual(pi.packages, hasLspPackage ? [...committedPackages, lspPackage] : committedPackages);
  assert.equal(hasLspPackage, hasLspMap, "Pi LSP package and server map must appear together");
  if (hasLspMap) {
    assert.deepEqual(Object.keys(pi.lsp.servers).sort(), ["gopls", "nixd", "pyright", "typescript"]);
  }
  if (requireUserOverlay) {
    assert.equal(hasLspPackage, true, "STEWARD_TEST_USER_OVERLAY=1 requires the Pi LSP package");
    assert.equal(hasLspMap, true, "STEWARD_TEST_USER_OVERLAY=1 requires the Pi LSP server map");
  }

  assert.equal(pi.homeFileNames.includes(".pi/agent/extensions/cc-tools.ts"), false);
  assert.deepEqual(
    [pi.defaultProvider, pi.defaultModel, pi.defaultThinkingLevel],
    ["openai-codex", "gpt-6-astra", "high"],
  );
  assert.equal(pi.models.providers["openai-codex"].models[0].id, "gpt-6-astra");
  assert.deepEqual(pi.tasks, { taskScope: "session-global", autoCascade: false, autoClearCompleted: "never" });
  assert.deepEqual(pi.goal, { rpc: { enabled: false }, continuationLimits: { automaticTurns: null, noProgressTurns: 3 } });
  assert.deepEqual(pi.subagents, {
    backgroundByDefault: false,
    strictAgentFiles: true,
    fallbackSubagent: "none",
    workflowsEnabled: false,
    schedulingEnabled: false,
  });
});

test("fresh Codex merge installs one stable trusted root Stop while retaining native approvals", () => {
  const target = "/home/tester/.codex/config.toml";
  const result = invokeMerge(desiredBaseline(), {}, target);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.json.hooks.Stop, [{ hooks: [ownHandler()] }]);
  const key = stateKey(target, 0, 0);
  assert.deepEqual(result.json.hooks.state[key], {
    enabled: true,
    trusted_hash: expectedHash(canonicalCommand),
  });
  assert.equal(result.json.approval_policy, "never");
  assert.equal(result.json.sandbox_mode, "danger-full-access");
  assert.deepEqual(result.json.tui.notifications, ["approval-requested"]);
  assert.equal(result.json.notify, undefined);
  assert.equal(result.json.hooks.SubagentStop, undefined);
});

test("Codex native hash matches the independently verified compact sorted JSON sample", () => {
  const sample = "/nix/store/synthetic-steward/bin/steward notify --harness codex";
  assert.equal(
    expectedHash(sample),
    "sha256:aecfc6d9b2aa324aa5999e71a25c273c1e11802e30f4733340b0155b2c1aac02",
  );
  const merged = invokeMerge(desiredBaseline(sample), {}, "/tmp/example/config.toml").json;
  assert.equal(merged.hooks.state["/tmp/example/config.toml:stop:0:0"].trusted_hash, expectedHash(sample));
});

test("Codex merge is idempotent and updates package command/hash in place", () => {
  const target = "/home/tester/.codex/config.toml";
  const oldCommand = "/nix/store/old-cc-tools/bin/cc-tools notify --harness codex";
  const first = invokeMerge(desiredBaseline(oldCommand), {}, target).json;
  const repeated = invokeMerge(desiredBaseline(oldCommand), first, target).json;
  assert.deepEqual(repeated, first);
  const changed = invokeMerge(desiredBaseline(), repeated, target).json;
  assert.equal(changed.hooks.Stop.length, 1);
  assert.deepEqual(changed.hooks.Stop[0].hooks, [ownHandler()]);
  assert.equal(changed.hooks.state[stateKey(target, 0, 0)].trusted_hash, expectedHash(canonicalCommand));
  assert.notEqual(changed.hooks.state[stateKey(target, 0, 0)].trusted_hash, first.hooks.state[stateKey(target, 0, 0)].trusted_hash);
});

test("Codex merge preserves unrelated Stop groups, state, projects, notifications, and appends at stable indices", () => {
  const target = "/home/tester/.codex/config.toml";
  const unrelatedHandler = { type: "command", command: "/opt/user/bin/backup", timeout: 3, async: true };
  const unrelatedKey = stateKey(target, 0, 0);
  const current = {
    approval_policy: "on-request",
    hooks: {
      Stop: [{ matcher: "all", hooks: [unrelatedHandler] }],
      state: {
        [unrelatedKey]: { enabled: false, trusted_hash: "sha256:user", note: "keep" },
      },
    },
    projects: { "/work/user": { trust_level: "trusted", marker: 7 } },
    tui: { notifications: ["approval-requested", "user-event"] },
    user_state: { keep: [1, 2, 3] },
  };
  const merged = invokeMerge(desiredBaseline(), current, target).json;
  assert.deepEqual(merged.hooks.Stop[0], current.hooks.Stop[0]);
  assert.deepEqual(merged.hooks.state[unrelatedKey], current.hooks.state[unrelatedKey]);
  assert.deepEqual(merged.hooks.Stop[1], { hooks: [ownHandler()] });
  assert.equal(merged.hooks.state[stateKey(target, 1, 0)].trusted_hash, expectedHash(canonicalCommand));
  assert.deepEqual(merged.projects, current.projects);
  assert.deepEqual(merged.user_state, current.user_state);
  assert.deepEqual(merged.tui.notifications, ["approval-requested"]);
  assert.equal(merged.approval_policy, "never");
});

test("Codex merge replaces one owned nonzero handler without moving siblings or unrelated trust", () => {
  const target = "/home/tester/.codex/config.toml";
  const oldCommand = "/nix/store/legacy/bin/cc-tools notify --harness codex";
  const left = { type: "command", command: "/opt/user/left" };
  const right = { type: "command", command: "/opt/user/right" };
  const ownKey = stateKey(target, 1, 1);
  const siblingKey = stateKey(target, 1, 2);
  const current = {
    hooks: {
      Stop: [
        { hooks: [{ type: "command", command: "/opt/user/first" }] },
        { matcher: "preserve", hooks: [left, ownHandler(oldCommand), right] },
      ],
      state: {
        [ownKey]: { enabled: false, trusted_hash: "sha256:old", extension: "preserved" },
        [siblingKey]: { enabled: false, trusted_hash: "sha256:right" },
      },
    },
  };
  const merged = invokeMerge(desiredBaseline(), current, target).json;
  assert.equal(merged.hooks.Stop.length, 2);
  assert.equal(merged.hooks.Stop[1].matcher, "preserve");
  assert.deepEqual(merged.hooks.Stop[1].hooks, [left, ownHandler(), right]);
  assert.deepEqual(merged.hooks.state[siblingKey], current.hooks.state[siblingKey]);
  assert.deepEqual(merged.hooks.state[ownKey], {
    enabled: true,
    trusted_hash: expectedHash(canonicalCommand),
    extension: "preserved",
  });
});

test("Codex merge removes only exact Steward legacy top-level notify", () => {
  const owned = invokeMerge(desiredBaseline(), {
    notify: ["/nix/store/old/bin/cc-tools", "notify"],
    marker: true,
  }).json;
  assert.equal(owned.notify, undefined);
  assert.equal(owned.marker, true);

  const userNotify = ["/opt/user/cc-tools-wrapper", "notify", "--harness", "codex"];
  const unrelated = invokeMerge(desiredBaseline(), { notify: userNotify }).json;
  assert.deepEqual(unrelated.notify, userNotify);
});

test("Codex duplicate-owned and SubagentStop migrations fail explicitly without touching target", () => {
  withTemp((directory) => {
    const baselinePath = join(directory, "baseline.json");
    const currentPath = join(directory, "current.json");
    const target = join(directory, "config.toml");
    const original = "# user config must survive\n";
    writeFileSync(target, original);
    chmodSync(target, 0o600);
    writeFileSync(baselinePath, JSON.stringify(desiredBaseline()));

    for (const [name, current, message] of [
      ["duplicate", { hooks: { Stop: [{ hooks: [ownHandler(), ownHandler("steward notify --harness codex")] }] } }, "multiple owned Steward Stop handlers"],
      ["subagent", { hooks: { SubagentStop: [{ hooks: [ownHandler("cc-tools notify --harness codex")] }] } }, "owned Steward SubagentStop migration is unsupported"],
    ]) {
      writeFileSync(currentPath, JSON.stringify(current));
      const result = spawnSync("python3", [helper, "--baseline", baselinePath, "--current", currentPath, "--target", target], { encoding: "utf8" });
      assert.notEqual(result.status, 0, `${name} unexpectedly succeeded`);
      assert.match(result.stderr, new RegExp(message));
      assert.equal(readFileSync(target, "utf8"), original);
      assert.equal(statSync(target).mode & 0o777, 0o600);
    }
  });
});

test("generated Codex activation is atomic, mode 0600, idempotent, and propagates merge errors", () => {
  const evaluated = evaluateCutover();
  withTemp((directory) => {
    const baseline = join(directory, "managed.toml");
    writeFileSync(
      baseline,
      evaluated.codex.managed.replaceAll("@STEWARD_PACKAGE@", "/nix/store/new-steward"),
    );
    const replacements = new Map([
      ["@BASE@", baseline],
      ["@COREUTILS@", commandRoot("mktemp")],
      ["@JQ@", commandRoot("jq")],
      ["@YQ@", nixPackageRoot("yq-go")],
      ["@PYTHON@", commandRoot("python3")],
    ]);
    let activation = evaluated.codex.activation;
    for (const [marker, value] of replacements) activation = activation.replaceAll(marker, value);
    activation = activation.replace(/\/nix\/store\/[a-z0-9]+-merge-config\.py/, helper);
    const home = join(directory, "home");
    const env = { ...process.env, HOME: home };
    const first = spawnSync("bash", ["-c", activation], { env, encoding: "utf8" });
    assert.equal(first.status, 0, first.stderr);
    const target = join(home, ".codex/config.toml");
    assert.equal(statSync(target).mode & 0o777, 0o600);
    const firstContents = readFileSync(target, "utf8");
    const firstInode = statSync(target).ino;
    const second = spawnSync("bash", ["-c", activation], { env, encoding: "utf8" });
    assert.equal(second.status, 0, second.stderr);
    assert.equal(readFileSync(target, "utf8"), firstContents);
    assert.equal(statSync(target).ino, firstInode, "idempotent activation rewrote the target");

    const duplicateJson = desiredBaseline();
    duplicateJson.hooks.Stop[0].hooks.push(ownHandler("cc-tools notify --harness codex"));
    const duplicateToml = execFileSync(join(nixPackageRoot("yq-go"), "bin/yq"), ["-p=json", "-o=toml", "."], {
      input: JSON.stringify(duplicateJson),
      encoding: "utf8",
    });
    writeFileSync(target, duplicateToml);
    chmodSync(target, 0o600);
    const beforeFailure = readFileSync(target);
    const failed = spawnSync("bash", ["-c", activation], { env, encoding: "utf8" });
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /multiple owned Steward Stop handlers/);
    assert.deepEqual(readFileSync(target), beforeFailure);
    assert.equal(statSync(target).mode & 0o777, 0o600);
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

test("cutover documentation separates clean and user-overlay gates and the deployment retirement check", () => {
  const documentation = readFileSync(resolve(repository, "docs/steward-cutover.md"), "utf8");
  assert.match(documentation, /node --test home-manager\/steward\/cutover\.test\.mjs/);
  assert.match(documentation, /STEWARD_TEST_USER_OVERLAY=1 node --test home-manager\/steward\/cutover\.test\.mjs/);
  assert.match(documentation, /clean owned commit/i);
  assert.match(documentation, /user deployment overlay/i);
  assert.match(documentation, /sd-switch/);
  assert.match(documentation, /cc-tools-notifyd.*inactive/is);
  assert.match(documentation, /steward-notifyd.*active/is);
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
  assert.match(readFileSync(resolve(repository, "home-manager/statusline-aliases/default.nix"), "utf8"), /steward resolve/);
  assert.match(readFileSync(resolve(repository, "home-manager/starship/default.nix"), "utf8"), /steward render-clouds/);
  assert.match(readFileSync(resolve(repository, "home-manager/hosts/shrike.nix"), "utf8"), /inputs\.steward\.packages/);
});
