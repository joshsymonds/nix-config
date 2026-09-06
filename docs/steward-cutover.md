# Steward consumer cutover

This configuration consumes `joshsymonds/steward` at
`bb73759898e69e61d993790d4ac5721ef3c2dd15`. It is a branch pin for the
coordinated consumer cutover, not a release claim.

## Shared ownership

`home-manager/steward/default.nix` is the sole common owner of the default
Steward package, the `steward-notifyd` user service, the ntfy age secrets, and
the canonical `STEWARD_*` environment. Shell sessions receive only secret-file
paths. The service expands agenix's runtime path in its shell, reads the
secrets at process start, and exports the effective Home Manager helper/model
values; no secret value enters the Nix store.

The desktop, headless, and minimal profiles already select Home Manager's
`sd-switch`. During generation activation, it receives both the old and new
unit directories and stops removed owned units, so no additional best-effort
`systemctl` activation is used to retire `cc-tools-notifyd`. This does not
delete historical state.

The paired `steward-pi-runtime` output supplies both Pi's extension root and
its physical `node_modules` graph. Pi runs from the same default Steward
package and loads the owned subagents wrapper before the owned extension. The
tasks and goal packages link `typebox` from that paired graph rather than from
a second Pi installation. When the separate user deployment overlay adds LSP,
its package uses the same graph and its configuration must publish all four
server mappings.

## Native consumers

- Claude keeps usage-summary refresh as its first root `Stop` command and then
  runs `steward notify --harness claude-code`. Only `permission_prompt` and
  `agent_needs_input` use the explicit-input notification hook. `SessionEnd`
  invokes Steward for cleanup, and no `SubagentStop` notification is present.
- Codex declares one synchronous, ten-second native root `Stop` command. The
  activation merge keeps its stable group/handler indices and writes only the
  exact user-scoped `hooks.state` trust hash. Unrelated hooks, state, projects,
  notifications, and native approval policy are preserved according to the
  existing baseline-wins merge. Duplicate owned handlers or an owned legacy
  `SubagentStop` fail without replacing `config.toml`.
- Pi gets root/child classification, settled notification, labels, footer, and
  quota integration from Steward's packaged extension. No consumer-side
  adapter or second pi-subagents package remains.

The Codex hash is SHA-256 over compact recursively key-sorted JSON containing
`event_name: "stop"` and the single normalized command handler. Its trust key
is `<absolute user config.toml>:stop:<group index>:<handler index>`; matcher is
not hashed and no global trust bypass is configured.

## Verification boundary

Run the normal lightweight gate on the clean owned commit. It verifies the
committed consumer obligations, including Pi's tasks, Steward, goal, and Astra
behavior. It also validates LSP package/map consistency if an LSP overlay is
present, but does not require that user-owned overlay:

```sh
node --test home-manager/steward/cutover.test.mjs
```

Run the explicit overlay gate on the retained user deployment overlay. This
mode requires the actual Pi LSP package and all four server mappings, Claude's
`chatgpt/astra` model with `xhigh` effort, and the committed Pi Astra behavior;
absence is a failure:

```sh
STEWARD_TEST_USER_OVERLAY=1 node --test home-manager/steward/cutover.test.mjs
```

Both modes parse the checked source directly and require no checkout-local Git
tree object or path. The opt-in native metadata smoke uses only Codex app-server
`initialize`/`initialized`/`hooks/list` in a network namespace. It performs no
model or hook execution:

```sh
STEWARD_NATIVE_HOOK_SMOKE=1 node home-manager/steward/native-hook-smoke.mjs
```

Package integration, host deployment, authenticated ntfy/model checks, and
controlled live acceptance remain separate root-owned steps. After deployment,
the required target check is that `cc-tools-notifyd.service` is inactive and
`steward-notifyd.service` is active (for example, inspect each with
`systemctl --user is-active`). In particular, Gnomon's Home Manager or NixOS
closure must only be built on Gnomon.
