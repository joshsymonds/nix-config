import { spawn } from 'node:child_process';
import { posix as path } from 'node:path';
import { TextDecoder } from 'node:util';

const OPERATIONS = new Set(['read', 'bash', 'grep', 'find', 'ls']);
const TRANSPORT_LIMIT = 2 * 1024 * 1024;
const BROKER_GRACE_MS = 3000;
const UTF8 = new TextDecoder('utf-8', { fatal: true });

const HELPER_SOURCE = String.raw`
import collections
import fnmatch
import json
import os
import pathlib
import re
import sys

MAX_BYTES = 50 * 1024
MARKER = "\n[Output truncated]\n"


def bounded(text, truncated=False):
    raw = text.encode("utf-8")
    if len(raw) > MAX_BYTES:
        truncated = True
    if truncated:
        budget = MAX_BYTES - len(MARKER.encode("utf-8"))
        raw = raw[:budget]
        while raw:
            try:
                text = raw.decode("utf-8")
                break
            except UnicodeDecodeError as error:
                raw = raw[:error.start]
        else:
            text = ""
        text += MARKER
    return {"text": text, "truncated": truncated}


def emit(text, truncated=False):
    sys.stdout.write(json.dumps(bounded(text, truncated), ensure_ascii=False, separators=(",", ":")))


def required_path(value):
    return os.path.abspath(value)


def read_chunked_line(handle, cap):
    parts = []
    used = 0
    while True:
        piece = handle.readline(min(8192, cap + 1 - used))
        if piece == "":
            return "".join(parts), False, not parts
        if "\x00" in piece:
            raise ValueError("binary input is unsupported")
        parts.append(piece)
        used += len(piece)
        if piece.endswith("\n"):
            return "".join(parts), False, False
        if used > cap:
            return "".join(parts)[:cap], True, False


def discard_line(handle):
    while True:
        piece = handle.readline(8192)
        if piece == "":
            return False
        if "\x00" in piece:
            raise ValueError("binary input is unsupported")
        if piece.endswith("\n"):
            return True


def do_read(args):
    source = required_path(args["path"])
    offset = args.get("offset", 1)
    limit = args.get("limit", 2000)
    pieces = []
    truncated = False
    try:
        with open(source, "r", encoding="utf-8", errors="strict", newline="") as handle:
            for _ in range(offset - 1):
                if not discard_line(handle):
                    emit("")
                    return
            for _ in range(limit):
                line, long_line, eof = read_chunked_line(handle, MAX_BYTES)
                if eof:
                    break
                pieces.append(line)
                if long_line:
                    truncated = True
                    break
                if len("".join(pieces).encode("utf-8")) > MAX_BYTES:
                    truncated = True
                    break
            if not truncated and handle.read(1) != "":
                truncated = True
    except UnicodeDecodeError as error:
        raise ValueError("binary or non-UTF-8 input is unsupported") from error
    emit("".join(pieces), truncated)


def walk_files(search_path):
    if not os.path.exists(search_path):
        raise FileNotFoundError(f"path not found: {search_path}")
    if os.path.isfile(search_path):
        yield search_path, os.path.basename(search_path)
        return
    if not os.path.isdir(search_path):
        raise ValueError(f"not a file or directory: {search_path}")
    for current, directories, files in os.walk(search_path, followlinks=False):
        directories.sort()
        files.sort()
        for name in files:
            full = os.path.join(current, name)
            yield full, os.path.relpath(full, search_path).replace(os.sep, "/")


def glob_match(relative, pattern):
    candidate = pathlib.PurePosixPath(relative)
    return candidate.match(pattern) or fnmatch.fnmatchcase(candidate.name, pattern)


def do_grep(args):
    search_path = required_path(args.get("path", "/workspace"))
    pattern = args["pattern"]
    ignore_case = args.get("ignoreCase", False)
    literal = args.get("literal", False)
    context_requested = args.get("context", 0)
    context = min(context_requested, 1000)
    limit = args.get("limit", 100)
    glob = args.get("glob")
    flags = re.IGNORECASE if ignore_case else 0
    expression = None if literal else re.compile(pattern, flags)
    needle = pattern.casefold() if ignore_case and literal else pattern
    output = []
    output_size = 0
    matches = 0
    extra_match = False
    truncated = context_requested > context

    def is_match(line):
        if expression is not None:
            return expression.search(line) is not None
        haystack = line.casefold() if ignore_case else line
        return needle in haystack

    def add_line(relative, number, line):
        nonlocal output_size, truncated
        visible = line.rstrip("\r\n")
        if len(visible) > 500:
            visible = visible[:497] + "..."
            truncated = True
        rendered = f"{relative}:{number}:{visible}\n"
        output.append(rendered)
        output_size += len(rendered.encode("utf-8"))
        if output_size > MAX_BYTES:
            truncated = True
            return False
        return True

    for full, relative in walk_files(search_path):
        if glob is not None and not glob_match(relative, glob):
            continue
        history = collections.deque(maxlen=context)
        after = 0
        last_emitted = 0
        try:
            with open(full, "r", encoding="utf-8", errors="strict", newline="") as handle:
                for number, line in enumerate(handle, 1):
                    matched = is_match(line)
                    if matched and matches < limit:
                        for previous_number, previous_line in history:
                            if previous_number > last_emitted:
                                if not add_line(relative, previous_number, previous_line):
                                    emit("".join(output), True)
                                    return
                                last_emitted = previous_number
                        if number > last_emitted:
                            if not add_line(relative, number, line):
                                emit("".join(output), True)
                                return
                            last_emitted = number
                        matches += 1
                        after = context
                    elif matched:
                        extra_match = True
                    elif after > 0:
                        if number > last_emitted:
                            if not add_line(relative, number, line):
                                emit("".join(output), True)
                                return
                            last_emitted = number
                        after -= 1
                    history.append((number, line))
                    if extra_match and after == 0:
                        break
        except (UnicodeDecodeError, ValueError):
            continue
        if extra_match:
            break
    emit("".join(output), truncated or extra_match)


def do_find(args):
    search_path = required_path(args.get("path", "/workspace"))
    if not os.path.exists(search_path):
        raise FileNotFoundError(f"path not found: {search_path}")
    pattern = args["pattern"]
    limit = args.get("limit", 1000)
    results = []

    def consider(relative, directory=False):
        plain = relative.rstrip("/")
        if glob_match(plain, pattern):
            results.append(plain + ("/" if directory else ""))
            return len(results) > limit
        return False

    if os.path.isfile(search_path):
        consider(os.path.basename(search_path))
    elif os.path.isdir(search_path):
        stop = False
        for current, directories, files in os.walk(search_path, followlinks=False):
            directories.sort()
            files.sort()
            for name in directories:
                relative = os.path.relpath(os.path.join(current, name), search_path).replace(os.sep, "/")
                if consider(relative, True):
                    stop = True
                    break
            if stop:
                break
            for name in files:
                relative = os.path.relpath(os.path.join(current, name), search_path).replace(os.sep, "/")
                if consider(relative):
                    stop = True
                    break
            if stop:
                break
    else:
        raise ValueError(f"not a file or directory: {search_path}")
    truncated = len(results) > limit
    emit("".join(f"{item}\n" for item in results[:limit]), truncated)


def do_ls(args):
    search_path = required_path(args.get("path", "/workspace"))
    if not os.path.exists(search_path):
        raise FileNotFoundError(f"path not found: {search_path}")
    if not os.path.isdir(search_path):
        raise ValueError(f"not a directory: {search_path}")
    limit = args.get("limit", 500)
    entries = []
    with os.scandir(search_path) as iterator:
        for entry in iterator:
            entries.append(entry.name + ("/" if entry.is_dir(follow_symlinks=False) else ""))
    entries.sort()
    truncated = len(entries) > limit
    emit("".join(f"{item}\n" for item in entries[:limit]), truncated)


try:
    request = json.load(sys.stdin)
    operation = request["operation"]
    arguments = request["args"]
    {"read": do_read, "grep": do_grep, "find": do_find, "ls": do_ls}[operation](arguments)
except Exception as error:
    operation = locals().get("operation", "helper")
    sys.stderr.write(f"{operation}: {error}\n")
    raise SystemExit(2)
`;

function shellQuote(value) {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

const HELPER_COMMAND = `python3 -c ${shellQuote(HELPER_SOURCE)}`;

function isPlainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function exactKeys(value, allowed) {
  return Object.keys(value).every((key) => allowed.includes(key));
}

function validString(value) {
  return typeof value === 'string' && !value.includes('\0');
}

function requiredString(args, key) {
  if (!Object.hasOwn(args, key) || !validString(args[key])) {
    throw new TypeError(`invalid arguments: ${key} must be a string`);
  }
}

function optionalString(args, key) {
  if (Object.hasOwn(args, key) && !validString(args[key])) {
    throw new TypeError(`invalid arguments: ${key} must be a string`);
  }
}

function optionalInteger(args, key, minimum, maximum = Number.MAX_SAFE_INTEGER) {
  if (Object.hasOwn(args, key)
      && (!Number.isSafeInteger(args[key]) || args[key] < minimum || args[key] > maximum)) {
    throw new TypeError(`invalid arguments: ${key} must be an integer between ${minimum} and ${maximum}`);
  }
}

function optionalBoolean(args, key) {
  if (Object.hasOwn(args, key) && typeof args[key] !== 'boolean') {
    throw new TypeError(`invalid arguments: ${key} must be a boolean`);
  }
}

function validateArguments(name, args) {
  if (!isPlainObject(args)) throw new TypeError('invalid arguments: expected an object');
  const allowed = {
    read: ['path', 'offset', 'limit'],
    bash: ['command', 'timeout'],
    grep: ['pattern', 'path', 'glob', 'ignoreCase', 'literal', 'context', 'limit'],
    find: ['pattern', 'path', 'limit'],
    ls: ['path', 'limit'],
  }[name];
  if (!exactKeys(args, allowed)) throw new TypeError('invalid arguments: unknown argument');

  if (name === 'read') requiredString(args, 'path');
  if (name === 'bash') requiredString(args, 'command');
  if (name === 'grep' || name === 'find') requiredString(args, 'pattern');
  optionalString(args, 'path');
  if (name === 'grep') optionalString(args, 'glob');
  optionalInteger(args, 'limit', 1);
  if (name === 'read') optionalInteger(args, 'offset', 1);
  if (name === 'bash') optionalInteger(args, 'timeout', 1, 120);
  if (name === 'grep') {
    optionalBoolean(args, 'ignoreCase');
    optionalBoolean(args, 'literal');
    optionalInteger(args, 'context', 0);
  }
}

function normalizedAbsolute(value) {
  return validString(value)
    && path.isAbsolute(value)
    && path.normalize(value) === value
    && (value === '/' || !value.endsWith('/'));
}

function validateSetup(config) {
  if (!isPlainObject(config)
      || !exactKeys(config, ['brokerPath', 'bundleRoot'])
      || Object.keys(config).length !== 2
      || !normalizedAbsolute(config.brokerPath)
      || !normalizedAbsolute(config.bundleRoot)) {
    throw new TypeError('invalid sandbox setup: brokerPath and bundleRoot must be normalized absolute paths');
  }
}

function killProcessGroup(child) {
  if (child.pid === undefined) return;
  try {
    process.kill(-child.pid, 'SIGKILL');
  } catch (error) {
    if (error.code !== 'ESRCH') {
      try {
        child.kill('SIGKILL');
      } catch {
        // The close/error event remains the authoritative cleanup result.
      }
    }
  }
}

function decodeUtf8(buffer) {
  try {
    return UTF8.decode(buffer);
  } catch (error) {
    throw new Error('invalid broker response: output is not UTF-8', { cause: error });
  }
}

function validateEnvelope(value) {
  const keys = ['exit_code', 'stderr', 'stdout', 'timed_out', 'truncated'];
  if (!isPlainObject(value)
      || Object.keys(value).sort().join('\0') !== keys.sort().join('\0')
      || typeof value.stdout !== 'string'
      || typeof value.stderr !== 'string'
      || !Number.isSafeInteger(value.exit_code)
      || typeof value.timed_out !== 'boolean'
      || typeof value.truncated !== 'boolean') {
    throw new Error('invalid broker response: malformed envelope');
  }
  return value;
}

function combinedText(stdout, stderr) {
  if (!stderr) return stdout;
  if (!stdout) return stderr;
  return `${stdout}${stdout.endsWith('\n') ? '' : '\n'}${stderr}`;
}

function visibleOutcome(text, envelope) {
  let result = text;
  const marker = envelope.timed_out ? '[command timed out]' : envelope.truncated ? '[output truncated]' : '';
  if (marker) {
    const suffix = `${result ? '\n' : ''}${marker}`;
    const budget = 256 * 1024 - Buffer.byteLength(suffix);
    while (Buffer.byteLength(result) > budget) result = result.slice(0, -1);
    result += suffix;
  }
  if (envelope.exit_code !== 0 && !result) result = `[command failed with exit code ${envelope.exit_code}]`;
  return result;
}

function helperResult(envelope) {
  if (envelope.exit_code !== 0 || envelope.timed_out || envelope.truncated) {
    return {
      text: visibleOutcome(combinedText(envelope.stdout, envelope.stderr), envelope),
      truncated: envelope.truncated,
    };
  }
  let response;
  try {
    response = JSON.parse(envelope.stdout);
  } catch (error) {
    throw new Error('invalid broker response: malformed helper output', { cause: error });
  }
  if (!isPlainObject(response)
      || Object.keys(response).sort().join('\0') !== ['text', 'truncated'].join('\0')
      || typeof response.text !== 'string'
      || typeof response.truncated !== 'boolean'
      || envelope.stderr !== '') {
    throw new Error('invalid broker response: malformed helper output');
  }
  return response;
}

function executeBroker(brokerPath, bundleRoot, name, args, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error('Operation aborted'));
      return;
    }

    const timeout = name === 'bash' ? (args.timeout ?? 120) : 120;
    const request = name === 'bash'
      ? { command: args.command }
      : { command: HELPER_COMMAND, stdin: JSON.stringify({ operation: name, args }) };
    const child = spawn(
      brokerPath,
      ['exec', '--bundle', bundleRoot, '--timeout', String(timeout)],
      { detached: true, env: {}, shell: false, stdio: ['pipe', 'pipe', 'pipe'] },
    );
    const stdout = [];
    const stderr = [];
    let buffered = 0;
    let settled = false;
    let aborted = false;
    let fatalError;

    const finish = (action) => {
      if (settled) return;
      settled = true;
      clearTimeout(watchdog);
      signal?.removeEventListener('abort', onAbort);
      action();
    };
    const failAndKill = (error) => {
      fatalError ??= error;
      killProcessGroup(child);
    };
    const collect = (target, chunk) => {
      buffered += chunk.length;
      if (buffered > TRANSPORT_LIMIT) {
        failAndKill(new Error('broker output limit exceeded'));
        return;
      }
      target.push(chunk);
    };
    const onAbort = () => {
      aborted = true;
      killProcessGroup(child);
    };
    signal?.addEventListener('abort', onAbort, { once: true });

    child.stdout.on('data', (chunk) => collect(stdout, chunk));
    child.stderr.on('data', (chunk) => collect(stderr, chunk));
    child.stdin.on('error', () => {
      // A failed broker can close stdin before consuming the request; close handles it.
    });
    child.on('error', (error) => {
      finish(() => reject(aborted
        ? new Error('Operation aborted')
        : new Error(`replay broker transport failed: ${error.message}`, { cause: error })));
    });
    child.on('close', (code, closeSignal) => {
      finish(() => {
        if (aborted) {
          reject(new Error('Operation aborted'));
          return;
        }
        if (fatalError) {
          reject(fatalError);
          return;
        }
        const stdoutBuffer = Buffer.concat(stdout);
        const stderrBuffer = Buffer.concat(stderr);
        let stderrText;
        try {
          stderrText = decodeUtf8(stderrBuffer);
        } catch (error) {
          reject(error);
          return;
        }
        if (code !== 0 || closeSignal !== null) {
          reject(new Error(stderrText.trim()
            ? `replay broker failed: ${stderrText.trim()}`
            : `replay broker failed with ${closeSignal ?? `exit code ${code}`}`));
          return;
        }
        try {
          const envelope = validateEnvelope(JSON.parse(decodeUtf8(stdoutBuffer)));
          const operation = name === 'bash'
            ? { text: visibleOutcome(combinedText(envelope.stdout, envelope.stderr), envelope), truncated: envelope.truncated }
            : helperResult(envelope);
          resolve({
            content: [{ type: 'text', text: operation.text }],
            details: {
              exit_code: envelope.exit_code,
              timed_out: envelope.timed_out,
              truncated: envelope.truncated || operation.truncated,
            },
          });
        } catch (error) {
          reject(error instanceof Error ? error : new Error(String(error)));
        }
      });
    });

    const watchdog = setTimeout(() => {
      failAndKill(new Error('replay broker exceeded its host lifetime limit'));
    }, timeout * 1000 + BROKER_GRACE_MS);
    watchdog.unref();
    child.stdin.end(JSON.stringify(request));
  });
}

export function createSandboxExecutor(config) {
  validateSetup(config);
  const brokerPath = config.brokerPath;
  const bundleRoot = config.bundleRoot;

  return Object.freeze({
    async execute(name, args, signal) {
      if (!OPERATIONS.has(name)) throw new TypeError(`unknown operation: ${String(name)}`);
      validateArguments(name, args);
      return executeBroker(brokerPath, bundleRoot, name, args, signal);
    },
  });
}
