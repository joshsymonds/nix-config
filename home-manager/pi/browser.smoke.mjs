#!/usr/bin/env node
// Usage: node browser.smoke.mjs <sdkRoot> <built-settings.json> <cli-bin-dir>
// Loads actual Pi resources, but invokes only the browser extension: no model,
// credentials, package installation, personal profile, or external test page.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync,
} from 'node:fs';
import { createServer } from 'node:http';
import { isAbsolute, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

assert.equal(process.argv.length, 5,
  'Usage: node browser.smoke.mjs <sdkRoot> <built-settings.json> <cli-bin-dir>');
const [sdkRoot, settingsPath, binDir] = process.argv.slice(2).map(path => resolve(path));
const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
// DefaultResourceLoader can install remote packages. Refuse them in this test.
for (const entry of [...(settings.packages ?? []), ...(settings.extensions ?? [])]) {
  const source = typeof entry === 'string' ? entry : entry.source;
  assert.ok(isAbsolute(source) && existsSync(source), `Expected built local resource: ${source}`);
}
const cli = join(binDir, 'agent-browser');
assert.ok(existsSync(cli), `Missing packaged CLI: ${cli}`);
const originalCwd = process.cwd();
const originalEnv = { ...process.env };
const originalUmask = process.umask(0o077);
// Short Unix socket paths are essential (especially on Darwin).
const scratch = mkdtempSync('/tmp/pib-');
const home = join(scratch, 'h');
const tmp = join(scratch, 't');
const sockets = join(scratch, 's');
const agentDir = join(scratch, 'a');
let extension;
let ctx;
let server;
let ordinal = 0;
const profiles = () => readdirSync(tmp).filter(name => name.startsWith('agent-browser-chrome-'));
const liveSockets = () => readdirSync(sockets).filter(name => /\.(pid|sock)$/.test(name));

try {
  for (const path of [home, tmp, sockets, agentDir, join(scratch, 'runtime')]) {
    mkdirSync(path, { recursive: true, mode: 0o700 });
  }
  for (const key of Object.keys(process.env)) {
    if (/^(AGENT_BROWSER_|PI_|XDG_)/.test(key)
      || /^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)$/i.test(key)
      || /(_API_KEY|_TOKEN|_SECRET)$/.test(key)) delete process.env[key];
  }
  Object.assign(process.env, {
    HOME: home,
    XDG_CONFIG_HOME: join(home, '.config'),
    XDG_CACHE_HOME: join(home, '.cache'),
    XDG_DATA_HOME: join(home, '.local/share'),
    XDG_STATE_HOME: join(home, '.local/state'),
    XDG_RUNTIME_DIR: join(scratch, 'runtime'),
    TMPDIR: tmp, TMP: tmp, TEMP: tmp,
    PI_CODING_AGENT_DIR: agentDir,
    PI_OFFLINE: '1',
    PI_AGENT_BROWSER_SOCKET_DIR: sockets,
    PI_AGENT_BROWSER_MANAGED_SESSION_RESTORE: '0',
    PATH: `${binDir}:${originalEnv.PATH ?? ''}`,
  });
  process.chdir(scratch);
  const { DefaultResourceLoader, SettingsManager, SessionManager } = await import(
    pathToFileURL(join(sdkRoot, 'dist/index.js')).href
  );
  const loader = new DefaultResourceLoader({
    cwd: scratch, agentDir,
    settingsManager: SettingsManager.inMemory(settings),
    noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  });
  await loader.reload();
  const loaded = loader.getExtensions();
  assert.deepEqual(loaded.errors, [], 'Pi must load all built extension resources without errors');
  const browserExtensions = loaded.extensions.filter(item => item.tools.has('agent_browser'));
  assert.equal(browserExtensions.length, 1, 'Exactly one native agent_browser tool must load');
  extension = browserExtensions[0];
  assert.deepEqual([...extension.tools.keys()], ['agent_browser'], 'No credential-backed search companion');
  assert.equal(loader.getSkills().skills.length, 0);
  console.log('PASS actual Pi DefaultResourceLoader / built settings / native browser tool');

  // Script-mode cleanup leases require a disk-backed SessionManager. Bind
  // only appendEntry; no AgentSession or model runtime is needed.
  const sessionManager = SessionManager.create(scratch, join(agentDir, 'sessions'));
  loaded.runtime.appendEntry = (type, data) => sessionManager.appendCustomEntry(type, data);
  ctx = {
    cwd: scratch, mode: 'print', hasUI: false, isProjectTrusted: () => false,
    sessionManager,
    ui: { notify() {}, setStatus() {} },
  };
  for (const handler of extension.handlers.get('session_start') ?? []) {
    await handler({ type: 'session_start', reason: 'startup' }, ctx);
  }
  assert.deepEqual(profiles(), [], 'Startup must not create a Chromium profile');
  assert.deepEqual(liveSockets(), [], 'Startup must not start a browser daemon');
  console.log('PASS startup creates no browser profile, PID or socket');

  server = createServer((_request, response) => {
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end(`<!doctype html><html><head><title>Pi Synthetic Smoke</title></head>
      <body><h1>Local browser fixture</h1>
      <button onclick="this.textContent='Clicked successfully';document.querySelector('p').textContent='State changed'">Click fixture</button>
      <p>Not clicked</p></body></html>`);
  });
  await new Promise((resolveListen, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolveListen);
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const tool = extension.tools.get('agent_browser').definition;
  async function run(params) {
    const result = await tool.execute(`smoke-${++ordinal}`, params,
      AbortSignal.timeout(60_000), undefined, ctx);
    assert.notEqual(result.isError, true, JSON.stringify(result));
    assert.notEqual(result.details?.resultCategory, 'failure', JSON.stringify(result));
    sessionManager.appendMessage({
      role: 'toolResult', toolName: 'agent_browser', toolCallId: `smoke-${ordinal}`,
      timestamp: Date.now(), ...result,
    });
    console.log('PASS', params.args?.join(' ') ?? 'isolated script');
    return result;
  }

  await run({ args: ['open', url] });
  assert.equal(profiles().length, 1, 'One ephemeral profile for the managed session');
  const before = await run({ args: ['snapshot', '-i'] });
  const ref = Object.entries(before.details?.data?.refs ?? {})
    .find(([, item]) => item.role === 'button' && item.name === 'Click fixture')?.[0];
  assert.ok(ref, 'Snapshot must supply a real button reference');
  await run({ args: ['click', `@${ref}`] });
  const after = await run({ args: ['snapshot', '-i'] });
  assert.match(JSON.stringify(after), /Clicked successfully/);
  assert.doesNotMatch(JSON.stringify(after.details?.data?.refs), /"name":"Click fixture"/);
  const screenshot = join(scratch, 'screenshot.png');
  await run({ args: ['screenshot', screenshot] });
  const png = readFileSync(screenshot);
  assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.equal(png.subarray(12, 16).toString(), 'IHDR');
  assert.ok(png.length > 1000 && png.readUInt32BE(16) > 0 && png.readUInt32BE(20) > 0,
    'Screenshot must be a nonempty, real PNG with nonzero dimensions');
  console.log(`PASS PNG ${png.length} bytes, ${png.readUInt32BE(16)}x${png.readUInt32BE(20)}`);

  // Script strips AGENT_BROWSER_*; it must still launch the Nix browser and
  // config via the CLI wrapper, using a second profile, not the managed one.
  const scriptResult = await run({ script: `
    const opened = await browser({ args: ['open', ${JSON.stringify(url)}] });
    if (!opened.ok) throw new Error('script open failed');
    const snapshot = await browser({ args: ['snapshot', '-i'] });
    if (!snapshot.ok) throw new Error('script snapshot failed');
    emit(snapshot);
  ` });
  assert.match(JSON.stringify(scriptResult), /Click fixture/,
    'Script must see a fresh, unclicked page');
  assert.equal(profiles().length, 1, 'Script must clean up its own ephemeral profile');
  const stillManaged = await run({ args: ['snapshot', '-i'] });
  assert.match(JSON.stringify(stillManaged), /Clicked successfully/,
    'Script must not navigate or close the original managed browser');
  await run({ args: ['close'] });
  assert.deepEqual(profiles(), [], 'Close must remove the managed ephemeral profile');
} finally {
  try {
    if (extension && ctx) {
      for (const handler of extension.handlers.get('session_shutdown') ?? []) {
        await handler({ type: 'session_shutdown', reason: 'quit' }, ctx);
      }
    }
  } finally {
    try {
      // Cover failures before the normal close and partially launched sessions.
      // Only touch session PIDs in this test's private socket directory.
      if (existsSync(sockets)) {
        for (const file of readdirSync(sockets).filter(name => name.endsWith('.pid'))) {
          execFileSync(cli, ['--session', file.slice(0, -4), 'close'], {
            env: { ...process.env, AGENT_BROWSER_SOCKET_DIR: sockets },
            timeout: 15_000, stdio: 'pipe',
          });
        }
      }
    } finally {
      if (server?.listening) {
        server.closeAllConnections();
        await new Promise(resolveClose => server.close(resolveClose));
      }
      process.chdir(originalCwd);
      for (const key of Object.keys(process.env)) delete process.env[key];
      Object.assign(process.env, originalEnv);
      process.umask(originalUmask);
      rmSync(scratch, { recursive: true, force: true });
    }
  }
}
console.log('PASS local open/snapshot/ref-click/changed-snapshot/PNG/script/close; cleaned up; no model calls');
