// Verify the generated context and Pi's built-in prompt compose correctly.
// This checks prompt wiring/content, not a guarantee of model behavior.
// node prompt.smoke.mjs <Pi SDK directory> <generated AGENTS.md>
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [sdkRoot, contextPath] = process.argv.slice(2);
assert.ok(sdkRoot && contextPath, 'Pass Pi SDK directory and generated AGENTS.md');
const context = readFileSync(contextPath, 'utf8');
for (const section of ['# Working with me', '# Communication', '# Progress updates', '# Delivering work', '# Pi tools']) {
  assert.ok(context.includes(section), `Missing approved instruction section: ${section}`);
}
assert.doesNotMatch(context, /under 120 words|8 lines|report only the files changed/i);
assert.match(context, /end with the specific action/i);
assert.match(context, /Before your first tool call/i);
assert.match(context, /verification results/i);
assert.match(context, /user owns scope and ambition/i);
assert.match(context, /test the changed behavior in an actual browser/i);
assert.match(context, /unfamiliar files/i);
assert.match(context, /Gambit owns planning/);
assert.equal(context, readFileSync(new URL('./AGENTS.md', import.meta.url), 'utf8'));

const { buildSystemPrompt } = await import(pathToFileURL(join(resolve(sdkRoot), 'dist/core/system-prompt.js')).href);
const prompt = buildSystemPrompt({
  cwd: '/synthetic/project',
  selectedTools: ['read', 'bash', 'edit', 'write', 'process'],
  toolSnippets: { process: 'Manage background processes' },
  promptGuidelines: ['Use exact replacement text for edits.', 'Do not poll managed processes.'],
  contextFiles: [{ path: contextPath, content: context }],
  skills: [],
});
assert.match(prompt, /You are an expert coding assistant operating inside pi/);
assert.match(prompt, /- process: Manage background processes/);
assert.match(prompt, /- Use exact replacement text for edits\./);
assert.match(prompt, /- Do not poll managed processes\./);
assert.ok(prompt.includes(context));
assert.match(prompt, /Current working directory: \/synthetic\/project/);
console.log('PASS generated personal guidance, action-item endings, progress updates, and preserved built-in/tool prompt composition');
