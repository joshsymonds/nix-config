import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import { createSandboxExecutor } from './tools.mjs';

const brokerPath = process.env.GAMBIT_REPLAY_BROKER;
assert.ok(brokerPath && path.isAbsolute(brokerPath), 'GAMBIT_REPLAY_BROKER must name the real accepted broker');

let testRoot;
let bundleRoot;
let workspace;
let hostCanary;
let executor;

before(async () => {
  testRoot = await mkdtemp(path.join(os.tmpdir(), 'gambit-tools-test-'));
  bundleRoot = path.join(testRoot, 'bundle');
  workspace = path.join(bundleRoot, 'candidate');
  hostCanary = path.join(testRoot, 'host-canary-secret.txt');
  await mkdir(bundleRoot, { mode: 0o700 });
  for (const projection of ['base', 'candidate', 'packet']) {
    await mkdir(path.join(bundleRoot, projection), { mode: 0o700 });
  }
  await mkdir(path.join(workspace, 'search', 'nested'), { recursive: true, mode: 0o700 });
  await mkdir(path.join(workspace, 'folder'), { mode: 0o700 });
  await writeFile(path.join(workspace, 'text.txt'), "first\nBeta quote ' and spaces\nthird\n", { mode: 0o600 });
  await writeFile(path.join(workspace, "quote ' file.txt"), 'quoted filename\n', { mode: 0o600 });
  await writeFile(path.join(workspace, '.hidden'), 'hidden\n', { mode: 0o600 });
  await writeFile(path.join(workspace, 'search', 'alpha.txt'), 'before\nAlpha42\nafter\nliteral a+b\nAlpha99\n', { mode: 0o600 });
  await writeFile(path.join(workspace, 'search', 'nested', 'beta.txt'), 'Alpha77\n', { mode: 0o600 });
  await writeFile(path.join(workspace, 'search', 'other.md'), 'Alpha55\n', { mode: 0o600 });
  await writeFile(path.join(workspace, 'binary.bin'), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 1, 2]), { mode: 0o600 });
  await writeFile(path.join(workspace, 'large.txt'), `${'x'.repeat(60 * 1024)}\n`, { mode: 0o600 });
  await writeFile(hostCanary, 'HOST_SECRET_MUST_NOT_ESCAPE\n', { mode: 0o600 });
  executor = createSandboxExecutor({ brokerPath, bundleRoot });
});

after(async () => {
  if (testRoot) await rm(testRoot, { recursive: true, force: true });
});

function textOf(result) {
  assert.deepEqual(result.content.map(({ type }) => type), ['text']);
  return result.content[0].text;
}

function assertDenied(result, operation) {
  assert.notEqual(result.details.exit_code, 0, `${operation} must preserve denial as failure`);
  assert.notEqual(textOf(result), '', `${operation} denial must remain visible`);
  assert.doesNotMatch(textOf(result), /HOST_SECRET_MUST_NOT_ESCAPE/);
}

async function makeSyntheticBroker(name, body) {
  const script = path.join(testRoot, name);
  await writeFile(script, `#!${process.execPath}\n${body}\n`, { mode: 0o700 });
  await chmod(script, 0o700);
  return script;
}

async function hostPidsContaining(marker) {
  const matches = new Set();
  for (const entry of await readdir('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const commandLine = await readFile(`/proc/${entry}/cmdline`);
      if (commandLine.includes(Buffer.from(marker))) matches.add(entry);
    } catch {
      // Processes can exit between listing and inspection.
    }
  }
  return matches;
}

async function waitForNewProcess(marker, baseline, timeoutMs = 2500) {
  const deadline = Date.now() + timeoutMs;
  do {
    const current = await hostPidsContaining(marker);
    if ([...current].some((pid) => !baseline.has(pid))) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  } while (Date.now() < deadline);
  assert.fail(`no new process containing ${marker} became active`);
}

async function waitForProcessCleanup(marker, baseline, timeoutMs = 2500) {
  const deadline = Date.now() + timeoutMs;
  do {
    const current = await hostPidsContaining(marker);
    if ([...current].every((pid) => baseline.has(pid))) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  } while (Date.now() < deadline);
  const current = await hostPidsContaining(marker);
  assert.deepEqual([...current].filter((pid) => !baseline.has(pid)), [], `processes containing ${marker} survived`);
}

test('captures fixed setup and sends only the exact broker CLI and request', async () => {
  const recorder = await makeSyntheticBroker('record-broker.mjs', `
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  process.stdout.write(JSON.stringify({
    stdout: JSON.stringify({ argv: process.argv.slice(2), request: JSON.parse(input) }),
    stderr: '', exit_code: 0, timed_out: false, truncated: false
  }));
});`);
  const config = { brokerPath: recorder, bundleRoot };
  const captured = createSandboxExecutor(config);
  config.brokerPath = '/does/not/exist';
  config.bundleRoot = '/changed';
  assert.ok(Object.isFrozen(captured));
  const result = await captured.execute('bash', { command: "printf '%s' 'quoted'", timeout: 7 });
  const received = JSON.parse(textOf(result));
  assert.deepEqual(received.argv, ['exec', '--bundle', bundleRoot, '--timeout', '7']);
  assert.deepEqual(received.request, { command: "printf '%s' 'quoted'" });
});

test('strictly rejects setup, operation, and argument shape errors before spawn', async () => {
  for (const config of [null, {}, { brokerPath: 'relative', bundleRoot }, { brokerPath, bundleRoot: 'relative' },
    { brokerPath: `${brokerPath}/../bad`, bundleRoot }, { brokerPath, bundleRoot, extra: true }]) {
    assert.throws(() => createSandboxExecutor(config), /sandbox setup/i);
  }
  const unavailable = createSandboxExecutor({ brokerPath: '/definitely/missing/replay-broker', bundleRoot });
  await assert.rejects(unavailable.execute('cat', {}), /unknown operation/i);
  const invalid = [
    ['read', {}], ['read', { path: '/workspace/text.txt', offset: 0 }], ['read', { path: 'x\0y' }],
    ['bash', {}], ['bash', { command: 'true', timeout: 121 }], ['bash', { command: 'true', timeout: 1.5 }],
    ['grep', {}], ['grep', { pattern: 'x', context: -1 }], ['grep', { pattern: 'x', ignoreCase: 'yes' }],
    ['grep', { pattern: 'x', glob: 3 }], ['find', {}], ['find', { pattern: '*', limit: 0 }],
    ['ls', { path: 3 }], ['ls', { surprise: true }], ['read', null], ['read', []],
  ];
  for (const [name, args] of invalid) {
    await assert.rejects(unavailable.execute(name, args), /argument/i, `${name} ${JSON.stringify(args)}`);
  }
  await assert.rejects(unavailable.execute('read', { path: '/workspace/text.txt' }), /ENOENT|spawn/i);
});

test('real broker preserves positive semantics, quoting, options, limits, and hidden entries', async () => {
  const read = await executor.execute('read', { path: '/workspace/text.txt', offset: 2, limit: 1 });
  assert.match(textOf(read), /^Beta quote ' and spaces\n/);
  assert.match(textOf(read), /truncated/i);
  assert.deepEqual(read.details, { exit_code: 0, timed_out: false, truncated: true });

  const bash = await executor.execute('bash', { command: `printf '%s\\n' "$PWD" "shell ' quote"` });
  assert.equal(textOf(bash), "/workspace\nshell ' quote\n");

  const grep = await executor.execute('grep', {
    pattern: 'alpha[0-9]+', path: '/workspace/search', glob: '*.txt', ignoreCase: true, context: 1, limit: 1,
  });
  assert.match(textOf(grep), /alpha\.txt:1:before/);
  assert.match(textOf(grep), /alpha\.txt:2:Alpha42/);
  assert.doesNotMatch(textOf(grep), /other\.md/);
  assert.equal(grep.details.exit_code, 0);
  assert.equal(grep.details.truncated, true);

  const literal = await executor.execute('grep', { pattern: 'a+b', path: '/workspace/search', literal: true });
  assert.match(textOf(literal), /alpha\.txt:4:literal a\+b/);

  const find = await executor.execute('find', { pattern: '**/*.txt', path: '/workspace', limit: 1 });
  assert.match(textOf(find), /\.txt/);
  assert.equal(find.details.truncated, true);

  const quotedFind = await executor.execute('find', { pattern: "quote ' *.txt", path: '/workspace' });
  assert.equal(textOf(quotedFind), "quote ' file.txt\n");

  const ls = await executor.execute('ls', { path: '/workspace', limit: 20 });
  assert.match(textOf(ls), /^\.hidden$/m);
  assert.match(textOf(ls), /^folder\/$/m);
  assert.match(textOf(ls), /^quote ' file\.txt$/m);
  const limitedLs = await executor.execute('ls', { path: '/workspace', limit: 1 });
  assert.equal(textOf(limitedLs).split('\n')[0], '.hidden');
  assert.equal(limitedLs.details.truncated, true);

  const scratchWrite = await executor.execute('bash', { command: "printf private > /tmp/per-call && cat /tmp/per-call" });
  assert.equal(textOf(scratchWrite), 'private');
  const scratchRead = await executor.execute('bash', { command: 'cat /tmp/per-call' });
  assert.notEqual(scratchRead.details.exit_code, 0);
});

test('real broker distinguishes no matches and command errors', async () => {
  const noGrep = await executor.execute('grep', { pattern: 'definitely absent', path: '/workspace/search' });
  assert.equal(noGrep.details.exit_code, 0);
  assert.equal(textOf(noGrep), '');
  const noFind = await executor.execute('find', { pattern: '*.never', path: '/workspace' });
  assert.equal(noFind.details.exit_code, 0);
  assert.equal(textOf(noFind), '');

  for (const [name, args] of [
    ['read', { path: '/workspace/missing' }],
    ['bash', { command: 'printf failure >&2; exit 9' }],
    ['grep', { pattern: 'x', path: '/workspace/missing' }],
    ['find', { pattern: '*', path: '/workspace/missing' }],
    ['ls', { path: '/workspace/text.txt' }],
  ]) {
    const result = await executor.execute(name, args);
    assert.notEqual(result.details.exit_code, 0, name);
    assert.notEqual(textOf(result), '', name);
  }
});

test('real broker denies the same private host canary through every operation', async () => {
  const probes = [
    ['read', { path: hostCanary }],
    ['bash', { command: `cat -- ${JSON.stringify(hostCanary)}` }],
    ['grep', { pattern: 'HOST_SECRET', path: hostCanary }],
    ['find', { pattern: '*', path: hostCanary }],
    ['ls', { path: hostCanary }],
  ];
  for (const [name, args] of probes) {
    assertDenied(await executor.execute(name, args), name);
  }
});

test('read explicitly rejects binary input and visibly bounds text output', async () => {
  const binary = await executor.execute('read', { path: '/workspace/binary.bin' });
  assert.notEqual(binary.details.exit_code, 0);
  assert.match(textOf(binary), /binary|UTF-8|text/i);

  const large = await executor.execute('read', { path: '/workspace/large.txt' });
  assert.equal(large.details.exit_code, 0);
  assert.equal(large.details.truncated, true);
  assert.match(textOf(large), /truncated/i);
  assert.ok(Buffer.byteLength(textOf(large)) <= 50 * 1024);
});

test('real broker visibly preserves output truncation and timeout', async () => {
  const output = await executor.execute('bash', { command: "python3 -c \"print('z' * 400000)\"" });
  assert.equal(output.details.truncated, true);
  assert.ok(Buffer.byteLength(textOf(output)) <= 256 * 1024);

  const timeout = await executor.execute('bash', { command: 'sleep 10', timeout: 1 });
  assert.equal(timeout.details.timed_out, true);
  assert.notEqual(timeout.details.exit_code, 0);
});

test('truncation clips multibyte output at a valid UTF-8 boundary', async () => {
  const output = await executor.execute('bash', {
    command: "python3 -c \"import sys; sys.stdout.buffer.write(('🙂' * 100000).encode())\"",
  });
  assert.equal(output.details.truncated, true);
  const text = textOf(output);
  assert.ok(Buffer.byteLength(text) <= 256 * 1024);
  assert.equal(Buffer.from(text).toString('utf8'), text);
  assert.match(text, /truncated/i);
});

test('pre-aborted and active cancellation reject only after broker cleanup', async () => {
  const pre = new AbortController();
  pre.abort();
  const unavailable = createSandboxExecutor({ brokerPath: '/definitely/missing/replay-broker', bundleRoot });
  await assert.rejects(unavailable.execute('bash', { command: 'true' }, pre.signal), /abort/i);

  const baseline = await hostPidsContaining(brokerPath);
  const active = new AbortController();
  const pending = executor.execute('bash', { command: 'sleep 30' }, active.signal);
  await waitForNewProcess(brokerPath, baseline);
  active.abort();
  await assert.rejects(pending, /abort/i);
  await waitForProcessCleanup(brokerPath, baseline);
});

test('transport and full-envelope failures reject without fallback and host buffering is bounded', async () => {
  const malformed = await makeSyntheticBroker('malformed-broker.mjs', `
process.stdin.resume();
process.stdin.on('end', () => process.stdout.write(JSON.stringify({ stdout: '', stderr: '', exit_code: 0, timed_out: false, truncated: false, extra: true })));`);
  await assert.rejects(
    createSandboxExecutor({ brokerPath: malformed, bundleRoot }).execute('bash', { command: 'true' }),
    /broker.*response|protocol/i,
  );

  const wrongTypes = await makeSyntheticBroker('wrong-types-broker.mjs', `
process.stdin.resume();
process.stdin.on('end', () => process.stdout.write(JSON.stringify({ stdout: 3, stderr: '', exit_code: 0, timed_out: false, truncated: false })));`);
  await assert.rejects(
    createSandboxExecutor({ brokerPath: wrongTypes, bundleRoot }).execute('bash', { command: 'true' }),
    /broker.*response|protocol/i,
  );

  const failed = await makeSyntheticBroker('failed-broker.mjs', `process.stderr.write('synthetic setup failure'); process.exit(2);`);
  await assert.rejects(
    createSandboxExecutor({ brokerPath: failed, bundleRoot }).execute('bash', { command: 'true' }),
    /synthetic setup failure/,
  );
  await assert.rejects(
    createSandboxExecutor({ brokerPath, bundleRoot: hostCanary }).execute('bash', { command: 'true' }),
    /replay broker failed/i,
  );

  const flood = await makeSyntheticBroker('flood-broker.mjs', `process.stdout.write('x'.repeat(3 * 1024 * 1024));`);
  await assert.rejects(
    createSandboxExecutor({ brokerPath: flood, bundleRoot }).execute('bash', { command: 'true', timeout: 1 }),
    /output.*limit|too large/i,
  );
});
