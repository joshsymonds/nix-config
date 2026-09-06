import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";

const here = dirname(fileURLToPath(import.meta.url));
const mergeHelper = resolve(here, "../codex/merge-config.py");
const command = "/nix/store/synthetic-steward/bin/steward notify --harness codex";

function hashFor(value) {
  const normalized = JSON.stringify({
    event_name: "stop",
    hooks: [{ async: false, command: value, timeout: 10, type: "command" }],
  });
  return `sha256:${createHash("sha256").update(normalized).digest("hex")}`;
}

function findOnPath(name) {
  return execFileSync("sh", ["-c", `command -v ${name}`], { encoding: "utf8" }).trim();
}

function merge(home) {
  const baseline = join(home, "baseline.json");
  const current = join(home, "current.json");
  const target = join(home, "config.toml");
  writeFileSync(baseline, JSON.stringify({
    hooks: { Stop: [{ hooks: [{ type: "command", command, timeout: 10, async: false }] }] },
  }));
  writeFileSync(current, "{}");
  const output = execFileSync(
    "python3",
    [mergeHelper, "--baseline", baseline, "--current", current, "--target", target],
    { encoding: "utf8" },
  );
  return JSON.parse(output);
}

function writeToml(config, path) {
  const handler = config.hooks.Stop[0].hooks[0];
  const key = `${path}:stop:0:0`;
  const state = config.hooks.state[key];
  assert.ok(state, `missing merged trust state ${key}`);
  const toml = [
    "[[hooks.Stop]]",
    "[[hooks.Stop.hooks]]",
    `type = ${JSON.stringify(handler.type)}`,
    `command = ${JSON.stringify(handler.command)}`,
    `timeout = ${handler.timeout}`,
    `async = ${handler.async}`,
    "",
    `[hooks.state.${JSON.stringify(key)}]`,
    `trusted_hash = ${JSON.stringify(state.trusted_hash)}`,
    `enabled = ${state.enabled}`,
    "",
  ].join("\n");
  writeFileSync(path, toml, { mode: 0o600 });
}

async function inspect(codex, home, cwd) {
  const child = spawn(
    "unshare",
    ["-Urn", codex, "app-server", "--stdio", "--strict-config"],
    {
      cwd,
      env: {
        HOME: home,
        CODEX_HOME: home,
        PATH: process.env.PATH,
        USER: process.env.USER ?? "steward-smoke",
        SHELL: "/bin/sh",
        RUST_LOG: "off",
      },
      stdio: ["pipe", "pipe", "pipe"],
    },
  );
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  const lines = createInterface({ input: child.stdout });
  const pending = new Map();
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  lines.on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  });

  const request = (id, method, params) => new Promise((resolveResponse, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timed out waiting for ${method}`));
    }, 12_000);
    timer.unref();
    pending.set(id, (message) => {
      clearTimeout(timer);
      resolveResponse(message);
    });
    child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
  });

  let tearingDown = false;
  const exitFailure = new Promise((_, reject) => {
    child.once("error", (error) => {
      if (!tearingDown) reject(error);
    });
    child.once("exit", (code, signal) => {
      if (!tearingDown) {
        reject(new Error(
          `Codex app-server exited before teardown (${code ?? signal}): ${stderr.slice(0, 500)}`,
        ));
      }
    });
  });

  try {
    await Promise.race([
      request(0, "initialize", {
        clientInfo: { name: "steward-native-smoke", version: "0.0.0" },
        capabilities: { experimentalApi: true },
      }),
      exitFailure,
    ]);
    child.stdin.write(`${JSON.stringify({ method: "initialized", params: {} })}\n`);
    const response = await Promise.race([
      request(1, "hooks/list", { cwds: [cwd] }),
      exitFailure,
    ]);
    assert.equal(response.error, undefined, JSON.stringify(response.error));
    const data = response.result.data[0];
    assert.deepEqual(data.errors, []);
    assert.equal(data.hooks.length, 1);
    return data.hooks[0];
  } finally {
    tearingDown = true;
    lines.close();
    child.stdin.destroy();
    child.kill("SIGTERM");
    await new Promise((resolveExit) => {
      if (child.exitCode !== null || child.signalCode !== null) {
        resolveExit();
        return;
      }
      const killTimer = setTimeout(() => child.kill("SIGKILL"), 2_000);
      child.once("exit", () => {
        clearTimeout(killTimer);
        resolveExit();
      });
    });
  }
}

async function main() {
  if (process.env.STEWARD_NATIVE_HOOK_SMOKE !== "1") {
    console.log("SKIP native Codex metadata smoke (set STEWARD_NATIVE_HOOK_SMOKE=1)");
    return;
  }

  const codex = process.env.STEWARD_CODEX_BIN || process.argv[2] || findOnPath("codex");
  const root = mkdtempSync(join(tmpdir(), "steward-native-hook-"));
  const home = join(root, "home");
  const cwd = join(root, "project");
  mkdirSync(home);
  mkdirSync(cwd);
  try {
    const merged = merge(home);
    const configPath = join(home, "config.toml");
    writeToml(merged, configPath);
    const trusted = await inspect(codex, home, cwd);
    assert.equal(trusted.key, `${configPath}:stop:0:0`);
    assert.equal(trusted.command, command);
    assert.equal(trusted.source, "user");
    assert.equal(trusted.enabled, true);
    assert.equal(trusted.isManaged, false);
    assert.equal(trusted.currentHash, hashFor(command));
    assert.equal(trusted.trustStatus, "trusted");

    merged.hooks.Stop[0].hooks[0].command = `${command} --dry-run`;
    writeToml(merged, configPath);
    const modified = await inspect(codex, home, cwd);
    assert.equal(modified.currentHash, hashFor(`${command} --dry-run`));
    assert.equal(modified.trustStatus, "modified");
    console.log("PASS native Codex user-hook trust metadata (trusted + modified)");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

await main();
