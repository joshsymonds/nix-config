# Preferences

- Delete replaced code completely. No `_v2` suffixes, no backwards-compatibility shims, no adapter patterns, no migration paths unless I ask for one. If something is declared somewhere, use it from there or restructure so it's available — don't wrap it
- When uncertain about architecture, stop and ask rather than guessing
- When reporting a bug, present diagnosis and evidence BEFORE implementing a fix. If I challenge a diagnosis, immediately pivot to investigating my suggested direction
- When fixing lint/test errors, fix ALL of them in one pass across the entire codebase. Do not dismiss failures as pre-existing or stop partway through

# Workflow

- After completing a task, run the project's test/lint/typecheck commands before reporting success
- When a task spans multiple files, finish all file changes before running verification — don't check iteratively per-file
- Never suggest /clear, context compaction, or comment on context length. I will manage context myself. Use the full context window without hesitation — do not slow down, hedge, or become conservative as context grows. If you notice degradation in your own outputs, say so directly without suggesting remediation

# Communication

- Be direct and terse in explanations. Skip preamble
- When presenting options, state your recommendation and why — don't just list pros/cons
- If you hit something unexpected, say what you found and what you think it means before asking what to do
