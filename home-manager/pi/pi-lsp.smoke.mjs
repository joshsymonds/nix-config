// Integration smoke test: real Pi loader + installed language servers, no model calls.
// node pi-lsp.smoke.mjs <pi-monorepo directory> <built settings.json> <built pi-lsp.json>
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { test } from "node:test";

const [sdkRoot, settingsPath, configPath] = process.argv.slice(2);
assert.ok(sdkRoot && settingsPath && configPath, "Pass SDK directory, settings, and LSP config");
const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
const lspPackage = settings.packages.find((p) => typeof p === "string" && /-pi-lsp-/.test(p));
assert.ok(lspPackage, "Nix settings must include the pinned pi-lsp package");
const scratch = mkdtempSync(join(tmpdir(), "pi-lsp-smoke-"));
const agentDir = join(scratch, "agent");
mkdirSync(agentDir);
writeFileSync(join(agentDir, "pi-lsp.json"), readFileSync(configPath));
process.env.PI_CODING_AGENT_DIR = agentDir;
process.env.PI_OFFLINE = "1";

const { DefaultResourceLoader, SettingsManager } = await import(
  pathToFileURL(join(resolve(sdkRoot), "dist/index.js")).href
);
const loader = new DefaultResourceLoader({
  cwd: scratch,
  agentDir,
  settingsManager: SettingsManager.inMemory({ packages: settings.packages }),
  noSkills: true,
  noPromptTemplates: true,
  noThemes: true,
  noContextFiles: true,
});

try {
  await loader.reload();
  const loaded = loader.getExtensions();
  assert.deepEqual(loaded.errors, [], "All configured package extensions must load together");
  const extension = loaded.extensions.find((e) => e.path.startsWith(lspPackage));
  assert.ok(extension, "Pi must discover pi-lsp from its package manifest");
  const diagnostics = extension.tools.get("lsp_diagnostics").definition;
  const fix = extension.tools.get("lsp_fix").definition;
  const notifications = [];
  const ctx = {
    cwd: scratch,
    isProjectTrusted: () => false,
    sessionManager: {},
    ui: { setStatus() {}, notify(message, level) { notifications.push({ message, level }); } },
  };

  await test("configured packages load together; all four LSP commands are available", async () => {
    await extension.commands.get("lsp").handler("", ctx);
    assert.equal(notifications.length, 1);
    assert.equal(notifications[0].level, "info", notifications[0].message);
    for (const server of ["nixd", "pyright", "typescript", "gopls"]) {
      assert.ok(notifications[0].message.includes(`${server} status: ready`));
    }
  });

  const fixtures = [
    ["nixd", "check.nix", "let value = ; in value\n", "let value = 1; in value\n"],
    ["pyright", "check.py", "value: int = \"bad\"\n", "value: int = 1\n"],
    ["typescript", "check.ts", "export const value: number = \"bad\";\n", "export const value: number = 1;\n"],
    ["gopls", "check.go", "package fixture\nvar Value int = \"bad\"\n", "package fixture\nvar Value int = 1\n"],
  ];
  for (const [server, filename, bad, good] of fixtures) {
    await test(`${server}: detects an error, then clears it after repair`, { timeout: 90000 }, async () => {
      const root = join(scratch, server);
      mkdirSync(root);
      if (server === "gopls") writeFileSync(join(root, "go.mod"), "module example.com/fixture\n\ngo 1.22\n");
      const file = join(root, filename);
      const run = async (text) => {
        writeFileSync(file, text);
        const result = await diagnostics.execute("smoke", { root, paths: [file], server },
          AbortSignal.timeout(40000), undefined, ctx);
        assert.equal(result.details.skipped.length, 0);
        assert.equal(result.details.routes.length, 1);
        const route = result.details.routes[0];
        assert.equal(route.server, server);
        assert.equal(route.details.summary.files, 1);
        return route.details.files.flatMap((f) => f.diagnostics);
      };
      const errors = await run(bad);
      assert.ok(errors.some((d) => d.severity === 1), JSON.stringify(errors));
      const clean = await run(good);
      assert.equal(clean.length, 0, JSON.stringify(clean));
    });
  }

  // TypeScript returns command-based actions that this extension cannot apply.
  // gopls returns WorkspaceEdits, so it exercises an actual preview mutation.
  await test("Go organize-imports previews a real edit without writing", { timeout: 60000 }, async () => {
    const root = join(scratch, "gopls");
    const file = join(root, "imports.go");
    const original = 'package fixture\nimport "fmt"\nvar Other = 1\n';
    writeFileSync(file, original);
    const result = await fix.execute("preview", {
      root, path: file, server: "gopls", kind: "source.organizeImports",
    }, AbortSignal.timeout(40000), undefined, ctx);
    assert.equal(result.details.write, false);
    assert.equal(result.details.changed, true);
    assert.ok(!result.details.text.includes("import"), result.details.text);
    assert.equal(readFileSync(file, "utf8"), original);
  });

  for (const handler of extension.handlers.get("session_shutdown") ?? []) {
    await handler({ type: "session_shutdown" }, ctx);
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
