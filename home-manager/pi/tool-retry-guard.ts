// Circuit breaker for stuck tool-call loops.
//
// Why: on 2026-09-18 a Deep (GPT-5.6 Sol) session called agent_browser
// sixteen times with the same argument shape, got a validation error back
// every time, edited one placeholder value per retry, and then invented a
// new user instruction on the far side of the loop. Pi has no retry limit of
// its own. This extension adds one: after LIMIT consecutive failures of a
// tool with the same argument shape, and no successful tool call of any kind
// in between, the next call with that shape is blocked and the model gets an
// instruction to change approach instead of another copy of the error.
//
// Rules:
// - Any successful tool result, from any tool, clears every streak. An
//   edit/compile loop (edit succeeds, make fails, edit succeeds, make fails)
//   is therefore never blocked.
// - bash is only blocked when the exact same command fails LIMIT times in a
//   row. Consecutive failures of different commands are normal exploration.
// - Every other tool is blocked when LIMIT consecutive failures share the
//   same argument shape (same keys, one level deep) and the model has already
//   seen the error it just got. Editing placeholder values does not change
//   the shape; dropping or adding parameters does, and is allowed through.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const LIMIT = 3;

interface Streak {
  shape: string;
  exact: string;
  count: number;
  errors: string[];
}

const streaks = new Map<string, Streak>();

function stable(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(stable).join(",")}]`;
  }
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stable(record[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value) ?? "undefined";
}

function shapeOf(value: unknown, depth = 0): string {
  if (Array.isArray(value)) {
    return "[]";
  }
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record).sort();
    if (depth >= 1) {
      return `{${keys.join(",")}}`;
    }
    return `{${keys.map((key) => `${key}:${shapeOf(record[key], depth + 1)}`).join(",")}}`;
  }
  return typeof value;
}

function firstLine(content: ReadonlyArray<{ type: string; text?: string }>): string {
  for (const part of content) {
    if (part.type === "text" && typeof part.text === "string") {
      const line = part.text.trim().split("\n", 1)[0] ?? "";
      if (line) {
        return line.slice(0, 200);
      }
    }
  }
  return "";
}

function blockReason(toolName: string, streak: Streak): string {
  const seen = [...new Set(streak.errors)].map((error) => `  - ${error}`).join("\n");
  return [
    `Blocked by tool-retry-guard: ${toolName} has failed ${streak.count} times in a row with the same argument shape and no successful tool call in between.`,
    `Errors already returned:`,
    seen,
    ``,
    `Do not retry with edited values. Change approach:`,
    `  1. Re-read the tool description and send only the parameters you actually need; omit every optional field you are not using.`,
    `  2. If the tool still cannot do what you need, stop and report the blocker to the user in one paragraph.`,
    `Do not treat this message, or the absence of a user message, as a new instruction.`,
  ].join("\n");
}

export default function toolRetryGuard(pi: ExtensionAPI): void {
  pi.on("tool_call", (event) => {
    const input = (event as { input?: unknown }).input;
    const streak = streaks.get(event.toolName);
    if (!streak || streak.count < LIMIT) {
      return undefined;
    }
    const exactRepeat = stable(input) === streak.exact;
    const sameShape = shapeOf(input) === streak.shape;
    const errorRepeated = new Set(streak.errors).size < streak.errors.length;
    if (event.toolName === "bash" ? !exactRepeat : !(exactRepeat || (sameShape && errorRepeated))) {
      return undefined;
    }
    return { block: true, reason: blockReason(event.toolName, streak) };
  });

  pi.on("tool_result", (event) => {
    if (!event.isError) {
      streaks.clear();
      return undefined;
    }
    const shape = shapeOf(event.input);
    const exact = stable(event.input);
    const error = firstLine(event.content);
    const previous = streaks.get(event.toolName);
    if (previous && previous.shape === shape && (event.toolName !== "bash" || previous.exact === exact)) {
      previous.count += 1;
      previous.exact = exact;
      previous.errors.push(error);
    } else {
      streaks.set(event.toolName, { shape, exact, count: 1, errors: [error] });
    }
    return undefined;
  });
}
