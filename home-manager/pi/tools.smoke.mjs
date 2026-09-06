// node tools.smoke.mjs <Pi SDK root> <built settings.json> <web config> <process config>
// Real tools and subprocesses; local fixtures plus public Exa/example.com requests.
// No model prompts or credentials. All test state is temporary.
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { createServer } from 'node:http';
import { join, resolve, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';
import { test } from 'node:test';
const [sdkRoot, settingsFile, webFile, processFile] = process.argv.slice(2).map(path => resolve(path));
assert.ok(processFile, 'Pass SDK root, settings, web config and process config');
const settings = JSON.parse(readFileSync(settingsFile, 'utf8'));
for (const entry of settings.packages) {
  const source = typeof entry === 'string' ? entry : entry.source;
  assert.ok(isAbsolute(source) && existsSync(source), `Only built local packages: ${source}`);
}
const root = mkdtempSync('/tmp/pi-tools-');
const agentDir = join(root, 'agent');
const oldCwd = process.cwd();
const notifications = [];
const changes = new EventEmitter();
let loaded, ctx, server;
let processesClosed = false;
function waitNotification(predicate) {
  const prior = notifications.find(predicate);
  if (prior) return Promise.resolve(prior);
  return new Promise((resolveWait, reject) => {
    const handler = value => { if (predicate(value)) { cleanup(); resolveWait(value); } };
    const timer = setTimeout(() => { cleanup(); reject(new Error('Notification deadline exceeded')); }, 10000);
    function cleanup() { clearTimeout(timer); changes.off('notification', handler); }
    changes.on('notification', handler);
  });
}
try {
  for (const dir of [agentDir, join(agentDir, 'extensions'), join(root, '.pi/extensions')]) mkdirSync(dir, { recursive: true });
  const webConfig = JSON.parse(readFileSync(webFile, 'utf8'));
  assert.equal(webConfig.searchProvider, 'exa');
  assert.equal(webConfig.workflow, 'none');
  assert.deepEqual(webConfig.fetchRouting.providers, ['http']);
  assert.deepEqual(webConfig.ssrf.allowRanges, []);
  // Only this isolated fixture configuration permits loopback fetches.
  webConfig.ssrf.allowRanges = ['127.0.0.0/8'];
  writeFileSync(join(agentDir, 'web-search.json'), JSON.stringify(webConfig));
  writeFileSync(join(agentDir, 'extensions/processes.json'), readFileSync(processFile));
  writeFileSync(join(root, '.pi/extensions/processes.json'), JSON.stringify({
    version: '0.10.6', execution: { shellPath: '/untrusted-project-must-not-run' },
  }));
  for (const key of Object.keys(process.env)) {
    if (/^(PI_|AGENT_BROWSER_|XDG_)/.test(key) || /(_API_KEY|_TOKEN|_SECRET)$/.test(key)
      || /^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)$/i.test(key)) delete process.env[key];
  }
  Object.assign(process.env, { HOME: root, TMPDIR: root, PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: '1' });
  process.chdir(root);
  const { DefaultResourceLoader, SettingsManager, SessionManager } = await import(pathToFileURL(join(sdkRoot, 'dist/index.js')).href);
  const loader = new DefaultResourceLoader({ cwd: root, agentDir,
    settingsManager: SettingsManager.inMemory(settings), noSkills: true,
    noPromptTemplates: true, noThemes: true, noContextFiles: true });
  await loader.reload();
  loaded = loader.getExtensions();
  assert.deepEqual(loaded.errors, [], 'All configured package extensions load together');
  const tools = new Map();
  for (const extension of loaded.extensions) for (const [name, tool] of extension.tools) {
    assert.ok(!tools.has(name), `Duplicate tool ${name}`);
    tools.set(name, tool.definition);
  }
  for (const name of ['process', 'web_search', 'fetch_content', 'get_search_content', 'source_check', 'agent_browser', 'lsp_diagnostics', 'Agent', 'TaskExecute']) {
    assert.ok(tools.has(name), `Missing tool: ${name}`);
  }
  console.log('PASS all new and existing tool schemas load together without collisions');
  loaded.runtime.sendMessage = (message, options) => {
    const value = { message, options };
    notifications.push(value);
    changes.emit('notification', value);
  };
  const denyCredentials = () => { throw new Error('Unexpected credential/model lookup'); };
  const sessionManager = SessionManager.inMemory(root);
  loaded.runtime.appendEntry = (type, data) => sessionManager.appendCustomEntry(type, data);
  ctx = { cwd: root, mode: 'print', hasUI: false, isProjectTrusted: () => false,
    isIdle: () => true, sessionManager,
    modelRegistry: { getApiKey: denyCredentials, find: denyCredentials, getAvailable: denyCredentials },
    ui: { notify() {}, setStatus() {}, setWidget() {} } };
  const run = (name, params) => tools.get(name).execute('smoke', params, AbortSignal.timeout(90000), undefined, ctx);

  await test('background process readiness wakes; stdin, logs and context-only exit work; project shell override ignored', async () => {
    const started = await run('process', { action: 'start', name: 'stdin-fixture',
      command: 'printf "READY\\n"; read -r input; printf "echo:%s\\n" "$input"',
      notify: { onSuccess: 'context', logMatches: [{ pattern: 'READY', on: 'turn' }] } });
    const id = started.details.process.id;
    const ready = await waitNotification(n => n.message.details.processId === id && n.message.details.kind === 'log_match');
    assert.deepEqual(ready.options, { triggerTurn: true, deliverAs: 'steer' });
    await run('process', { action: 'write', id, input: 'fixture-value\n', end: true });
    const done = await waitNotification(n => n.message.details.processId === id && n.message.details.kind === 'success');
    assert.equal(done.message.details.exitCode, 0);
    assert.deepEqual(done.options, { triggerTurn: false, deliverAs: 'nextTurn' });
    const output = await run('process', { action: 'output', id });
    assert.match(JSON.stringify(output), /echo:fixture-value/);
  });
  await test('nonzero process exit reports failure and wakes', async () => {
    const started = await run('process', { action: 'start', name: 'failure-fixture', command: 'printf "fixture-error\\n" >&2; exit 7' });
    const failure = await waitNotification(n => n.message.details.processId === started.details.process.id && ['failure', 'crash'].includes(n.message.details.kind));
    assert.equal(failure.message.details.exitCode, 7);
    assert.equal(failure.options.triggerTurn, true);
  });
  await test('stop terminates a real process without approval or automatic task changes', async () => {
    const started = await run('process', { action: 'start', name: 'stop-fixture', command: 'sleep 60' });
    const { id, pid } = started.details.process;
    await run('process', { action: 'stop', id });
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    const stopped = await waitNotification(n => n.message.details.processId === id && n.message.details.kind === 'killed');
    assert.equal(stopped.options.triggerTurn, false);
  });

  server = createServer((req, res) => {
    if (req.url === '/redirect') { res.writeHead(302, { Location: '/article' }); res.end(); return; }
    if (req.url === '/missing') { res.writeHead(404, { 'Content-Type': 'text/plain' }); res.end('fixture-not-found'); return; }
    if (req.url === '/fixture.pdf') {
      // A real, minimal one-page PDF with a standard embedded text stream.
      const stream = 'BT /F1 12 Tf 72 720 Td (Pi PDF evidence 72641) Tj ET';
      const objects = [
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
        `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`,
      ];
      let pdf = '%PDF-1.4\n';
      const offsets = [0];
      objects.forEach((object, index) => { offsets.push(pdf.length); pdf += `${index + 1} 0 obj\n${object}\nendobj\n`; });
      const xref = pdf.length;
      pdf += `xref\n0 6\n0000000000 65535 f \n${offsets.slice(1).map(offset => String(offset).padStart(10, '0') + ' 00000 n \n').join('')}trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
      res.setHeader('Content-Type', 'application/pdf'); res.end(pdf); return;
    }
    res.setHeader('Content-Type', 'text/html');
    res.end('<!doctype html><html><head><title>Pi retrieval fixture</title></head><body><article><h1>Pi retrieval fixture</h1><p>A synthetic document verifies direct extraction without credentials or model calls. The unique evidence marker is PIFIXTURE72641.</p><p>' + 'This article contains enough explanatory text for readability extraction. '.repeat(15) + '</p></article></body></html>');
  });
  await new Promise(resolveListen => server.listen(0, '127.0.0.1', resolveListen));
  const url = `http://127.0.0.1:${server.address().port}`;
  await test('raw/readable HTTP extraction and redirects preserve source evidence', async () => {
    for (const [path, mode] of [['/article', 'raw'], ['/redirect', 'readable']]) {
      const result = await run('fetch_content', { url: url + path, mode });
      assert.match(JSON.stringify(result), /PIFIXTURE72641/);
      assert.notEqual(result.isError, true, JSON.stringify(result));
    }
    const missing = await run('fetch_content', { url: url + '/missing', mode: 'readable' });
    assert.match(JSON.stringify(missing), /404/);
  });
  await test('public keyless Exa search returns actual source URLs without credential lookup or curator', async () => {
    const before = notifications.length;
    const result = await run('web_search', { query: 'NixOS manual', numResults: 2, includeContent: false });
    const text = JSON.stringify(result);
    assert.notEqual(result.isError, true, text);
    assert.equal(result.details.successfulQueries, 1);
    assert.ok(result.details.totalResults > 0);
    assert.equal(result.details.summary, undefined);
    assert.match(text, /https:\/\//);
    assert.match(text, /nixos\.org|nix\.dev|nix\.community/i);
    assert.equal(notifications.length, before, 'No background curator or summary completion');
    const recalled = await run('get_search_content', { responseId: result.details.searchId, queryIndex: 0 });
    assert.match(JSON.stringify(recalled), /nixos\.org|nix\.dev|nix\.community/i);
  });
  await test('local PDF extraction returns text without model or cloud conversion', async () => {
    const result = await run('fetch_content', { url: url + '/fixture.pdf' });
    assert.equal(result.details.successful, 1);
    const path = result.content.find(item => item.type === 'text').text.match(/saved to: (.+)/)?.[1];
    assert.ok(path?.startsWith(root + '/'), 'PDF artifact must stay in test scratch directory');
    assert.match(readFileSync(path, 'utf8'), /Pi PDF evidence 72641/);
  });
  await test('direct public raw fetch works for a page too short for readability extraction', async () => {
    const result = await run('fetch_content', { url: 'https://example.com', mode: 'raw' });
    assert.match(JSON.stringify(result), /Example Domain/);
  });
  await test('session shutdown terminates owned processes and removes temporary logs', async () => {
    const started = await run('process', { action: 'start', name: 'shutdown-fixture', command: 'sleep 60' });
    const { pid, stdoutFile } = started.details.process;
    assert.ok(existsSync(stdoutFile));
    for (const extension of loaded.extensions.filter(e => /pi-processes/.test(e.path))) {
      for (const handler of extension.handlers.get('session_shutdown') ?? []) await handler({ type: 'session_shutdown', reason: 'quit' }, ctx);
    }
    processesClosed = true;
    // Upstream cleanup signals synchronously; the OS reaps the child later.
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      try { process.kill(pid, 0); } catch (error) { if (error.code === 'ESRCH') break; throw error; }
      await new Promise(resolveTick => setTimeout(resolveTick, 10));
    }
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    assert.equal(existsSync(stdoutFile), false);
  });
} finally {
  if (loaded && ctx) {
    for (const extension of loaded.extensions.filter(e => /pi-processes|pi-web-access/.test(e.path))) {
      if (processesClosed && /pi-processes/.test(extension.path)) continue;
      for (const handler of extension.handlers.get('session_shutdown') ?? []) await handler({ type: 'session_shutdown', reason: 'quit' }, ctx);
    }
  }
  if (server?.listening) { server.closeAllConnections(); await new Promise(resolveClose => server.close(resolveClose)); }
  process.chdir(oldCwd);
  rmSync(root, { recursive: true, force: true });
}
