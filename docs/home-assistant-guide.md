# Home Assistant Development Guide

This repository treats Home Assistant as a first-class Nix service that runs on the `ultraviolet` host (`hosts/ultraviolet/home-assistant.nix`). All user-facing automations, dashboards, and reusable blueprints are checked into git so we can review and reproduce changes just like any other module. Use this document whenever you need to understand the existing setup or create new Home Assistant features.

## Architecture Snapshot

- **Runtime**: Home Assistant runs on `ultraviolet` (NixOS) at `172.31.0.200`. It listens on `http://172.31.0.200:8123`, is reverse-proxied by Caddy at `https://homeassistant.home.husbuddies.gay`, and advertises `https://home.husbuddies.gay` externally via Cloudflare Tunnel for mobile apps and TTS callbacks.
- **Configuration source**: `hosts/ultraviolet/home-assistant.nix` declares the `services.home-assistant` block, packages custom template sensors, and wires supporting services (Wyoming voice stack, BLE passthrough component, backups, etc.). The file also installs HACS, manages `secrets.yaml`, and exposes commands such as `ha-backup`/`ha-restore`.
- **Git-managed content**: Dashboards, automations, and blueprints live under the repo root `home-assistant/`. The Home Assistant systemd unit’s `preStart` script wipes `/var/lib/hass/{dashboards,automations,blueprints}` and recopies this tree on every restart, so your YAML changes here are the canonical source of truth.
- **Packages**: Template sensors and grouped helpers are packaged in Nix under `homeassistant.packages` for: bike tracking, car tracking, leak summaries, and BLE keychain buttons. These live in the top of `hosts/ultraviolet/home-assistant.nix` to keep advanced Jinja logic versioned with Nix.
- **Secrets**: Copy `hosts/ultraviolet/home-assistant-secrets.yaml.example` to `/var/lib/hass/secrets.yaml` (or `/etc/hass-secrets.yaml` during provisioning) and fill in coordinates, API keys, ntfy topics, etc. Never commit real secrets.

## Access & Tooling

### Web & API access

- UI endpoints: `https://home.husbuddies.gay` (external) and `https://homeassistant.home.husbuddies.gay` (Cloudflare-proxied Caddy). Use MFA (TOTP) configured in `homeassistant.auth_mfa_modules`. Internally you can use `http://172.31.0.200:8123`.
- Z-Wave JS lives on `bluedesert` (`ws://172.31.0.201:3000`). Voice services (Wyoming Whisper and Piper) are co-located on `ultraviolet` and exposed in the HA config.

### hass-cli wrapper

- Command: `hass-cli ...` is a wrapped binary declared in `hosts/ultraviolet/home-assistant/scripts/hass-cli.sh`.
- It auto-sets `HASS_SERVER=http://localhost:8123` and reads the token from `~/.config/home-assistant/token`. Create this file containing a long-lived access token (chmod `600`) if it does not exist.
- Helpful commands:
  - `hass-cli state list -o table | grep leak`
  - `hass-cli state get sensor.josh_nice_bike_location -o json`
  - `hass-cli service call cover.open_cover --data '{"entity_id": "cover.garage_door"}'`
  - Use `--wrap-timeout 30s` if you want to abort long-running commands; the wrapper falls back to `timeout`/`gtimeout`.
- You can always run `hass-cli --help` or view the script for supported environment variables (`HASS_TOKEN`, `HASS_SERVER`, `HASS_CLI_WRAP_TIMEOUT`).

### Backups and restores

- `ha-backup` (from `hosts/ultraviolet/home-assistant/scripts/backup-ha.sh`) copies `/var/lib/hass` to `/mnt/backups/home-assistant/<timestamp>`. A systemd service runs it nightly at 03:00 with log output recorded via `logger`.
- `ha-restore [latest|backup-...]` is a helper wrapper over `systemd`’s restore unit. The full recovery runbook lives in `hosts/ultraviolet/HOME-ASSISTANT-BACKUP.md`.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `hosts/ultraviolet/home-assistant.nix` | Primary Nix module that declares Home Assistant, template packages (`keychainPackage`, `bikePackage`, `carPackage`, `leaksPackage`), enabled integrations, Lovelace configuration, helpers, HTTP proxying, and systemd units. |
| `home-assistant/dashboards/` | YAML-mode Lovelace dashboards (`ui-lovelace.yaml`) plus `views/`, `cards/`, `popups/`, and `popup-content/`. Uses Bubble Card, Auto Entities, Browser Mod pop-ups, and shared YAML anchors defined in `cards/templates.yaml`. |
| `home-assistant/automations/` | Automation lists grouped by domain (garage/bike/car, BLE keychains, leak handling). Files are merged via `!include_dir_merge_list automations`. |
| `home-assistant/blueprints/automation/garage/` | Reusable proximity-arrival and proximity-departure blueprints powering garage-door logic. |
| `hosts/ultraviolet/home-assistant/scripts/` | Shell helpers for `hass-cli` wrapping and `backup-ha`. |
| `hosts/ultraviolet/home-assistant/templates/` | Legacy template fragments (currently BLE keychain template) kept for reference; most templates now live directly in the Nix package definitions. |
| `hosts/ultraviolet/home-assistant-secrets.yaml.example` | Example secrets file to copy and fill on the host. |
| `hosts/ultraviolet/HOME-ASSISTANT-BACKUP.md` | Detailed backup/restore instructions for production incidents. |

## What the Current Setup Does

- **Garage automation**: `home-assistant/automations/bike.yaml` and `car.yaml` use the custom blueprints in `home-assistant/blueprints/automation/garage/` to open and close the garage door based on distance sensors (`sensor.joshs_nice_bike_distance`, `sensor.bcpro_201403_distance`) and Tailwind/cover state. Cooldowns and guard booleans (`input_boolean.nice_bike_should_open`, `input_boolean.honda_crv_should_open`) prevent flapping, and automations coordinate with each other to avoid double triggers.
- **BLE keychain buttons**: `home-assistant/automations/keychain.yaml` listens for `ble_passthrough.adv_received` events emitted by the custom `ble_passthrough` component cloned in `services.home-assistant` `preStart`. Josh and Justin’s keychains toggle the garage and expose occupancy-style binary sensors for dashboards. Supporting template entities reside in `keychainPackage`.
- **Vehicle tracking packages**: `bikePackage` and `carPackage` in `hosts/ultraviolet/home-assistant.nix` normalize the “Bermuda” tracker attributes into friendly sensors like `sensor.josh_nice_bike_location`, `sensor.josh_nice_bike_last_seen`, and `binary_sensor.josh_nice_bike_offline` so automations/dashboards can key off zones, offline detection, and derived metadata.
- **Water leak response**: The `leaksPackage` creates `sensor.leak_alert_summary` with ack/snooze state, icon colors, and action labels used across the UI. `home-assistant/automations/water-leaks.yaml` fans out to (1) critical push notifications, (2) Sonos Move TTS with leak-specific announcements, and (3) repeating reminders until the leak is acknowledged or snoozed. Helpers (`input_boolean.leak_ack_*`, `timer.leak_alert_snooze`) and UI cards (`home-assistant/dashboards/views/01-overview.yaml` sections) are all wired to this package.
- **Dashboards & pop-ups**: `home-assistant/dashboards/ui-lovelace.yaml` loads `views/01-overview.yaml`, which in turn includes `overview-cards` for each room, sections for garage/leaks/ADU, and Browser Mod pop-up preloaders. Cards reference anchors from `cards/templates.yaml` for consistent styling, while pop-up definitions live under `dashboards/popups/` with their content in `dashboards/popup-content/`. Because Lovelace runs in YAML mode (`lovelace.mode = "yaml"`), every change must go through git and a Nix rebuild.
- **Voice & media**: Extra components enable Piper TTS, Sonos, Spotify, Denon AVR, WebOS TVs, Jellyfin, Radarr/Sonarr, SABnzbd, and HomeKit Controller. Automations call `tts.piper` and `sonos.snapshot/restore` for alerts.
- **Monitoring & integrations**: Enabled integrations in `extraComponents` cover Hue, Lutron Caseta, UniFi, Tailwind, Todoist, MQTT, Wyze (via `ble_passthrough`), Uptime/System Monitor, Z-Wave JS, and more. The HTTP server trusts local proxies (`http.trusted_proxies`) because Caddy terminates TLS.

## Working With `hass-cli`

1. Ensure you have a long-lived token stored at `~/.config/home-assistant/token`.
2. Run `hass-cli state list` to discover entity IDs and attributes.
3. Combine with standard shell tools to filter (`hass-cli state list -o table | rg bike`).
4. Use `hass-cli service call <domain>.<service> --data '{"entity_id": "..."}'` to test new automations before codifying them.
5. For JSON output you can pipe to `jq` (`hass-cli state list -o json | jq '.[] | select(.entity_id | contains(\"leak\"))'`).

## Workflow for New Features

1. **Decide where the change lives**:
   - Sensors/helpers/templates → edit `hosts/ultraviolet/home-assistant.nix` (within the relevant package or `homeassistant.config` section) so Nix owns the entity definition.
   - Automations → add/update YAML under `home-assistant/automations/`. Each file exports a list (`- id: ...`). Keep topics separated (e.g., `garage.yaml`, `water-leaks.yaml`) so merges stay clean.
   - Dashboards → modify `home-assistant/dashboards/ui-lovelace.yaml`, add new card files under `dashboards/views/`, `cards/`, or `popups/`, and reuse anchors in `cards/templates.yaml`. Remember Lovelace is YAML-only; UI editor changes will be overwritten by the next restart.
   - Blueprints → create a new file under `home-assistant/blueprints/automation/<namespace>/` if you need reusable logic.
   - Shell tooling/backup flows → update `hosts/ultraviolet/home-assistant/scripts/` or the matching systemd service definitions.
2. **Explore the current state** with `hass-cli` or the UI to capture entity IDs, attributes, and service payloads. This ensures your automation references real sensors.
3. **Validate syntax**: run `yamllint` against edited files (`yamllint home-assistant/automations/water-leaks.yaml`). For Nix edits run `nix fmt`, then `nix flake check` at the repo root (remember `git add` any new files first — flakes only see tracked files).
4. **Deploy**: run `update` (the `writeShellScriptBin` on `PATH`; runs `nh os switch` under the hood) or `sudo nixos-rebuild switch --flake .#ultraviolet` to push changes onto the host. The Home Assistant service has `restartTriggers` on the `home-assistant/{dashboards,automations,blueprints}` paths so it restarts and recopies all YAML automatically.
5. **Verify**: tail logs via `sudo journalctl -fu home-assistant.service`, open the UI, and run `hass-cli state get …` to confirm entities/cards appear. For Lovelace edits also clear browser cache or reload the browser.
6. **Back up**: when landing big changes, trigger an on-demand backup (`ha-backup my-new-automation`) so you can roll back quickly. Details live in `hosts/ultraviolet/HOME-ASSISTANT-BACKUP.md`.

Following this workflow ensures new features stay reproducible, reviewed, and easy for future agents to iterate on.
