{
  pkgs,
  lib,
  ...
}: let
  # Create a package for the backup script
  ha-backup-script = pkgs.writeShellScriptBin "backup-ha" (
    builtins.readFile ./home-assistant/scripts/backup-ha.sh
  );
  # Wrap hass-cli to auto-set server and token (script content on disk for readability)
  hassCliWrapped = pkgs.writeShellScriptBin "hass-cli" (
    (builtins.readFile ./home-assistant/scripts/hass-cli.sh)
    + ''
      REAL_HASS_CLI=${pkgs.home-assistant-cli}/bin/hass-cli
      run_hass_cli "$REAL_HASS_CLI" "$@"
    ''
  );
  keychainPackage = {
    template = [
      {
        binary_sensor = [
          {
            name = "Josh Keychain Button Press Signal";
            unique_id = "josh_keychain_button_pressed_signal";
            device_class = "occupancy";
            state = "{{ is_state('input_boolean.josh_keychain_button_pressed', 'on') }}";
          }
          {
            name = "Justin Keychain Button Press Signal";
            unique_id = "justin_keychain_button_pressed_signal";
            device_class = "occupancy";
            state = "{{ is_state('input_boolean.justin_keychain_button_pressed', 'on') }}";
          }
        ];
      }
    ];
  };
  bikePackage = {
    template = [
      {
        sensor = [
          {
            name = "Josh Nice Bike Location";
            unique_id = "sensor_josh_nice_bike_location";
            icon = "mdi:bicycle";
            state = ''
              {% set tracker = states.device_tracker.joshs_nice_bike_bermuda_tracker %}
              {% set bermuda = tracker.state if tracker else 'unknown' %}
              {% set last_known = this.attributes.last_known_zone | default('not_home') %}
              {% set last_seen_prev = this.attributes.last_seen_ts | default(none) %}
              {% set area_attr = tracker.attributes.get('area') if tracker else none %}
              {% set normalized_area = area_attr | lower | replace(' ', '_') if area_attr is not none else none %}
              {% if tracker %}
                {% set raw_last = tracker.attributes.get('last_seen') %}
                {% if raw_last %}
                  {% set last_seen_ts = as_timestamp(raw_last) %}
                {% else %}
                  {% set last_seen_ts = as_timestamp(tracker.last_changed) %}
                {% endif %}
              {% else %}
                {% set last_seen_ts = last_seen_prev %}
              {% endif %}
              {% set homeish = ['garage', 'driveway', 'front_deck', 'home'] %}
              {% set offline_threshold = 900 %}
              {% set elapsed = (now().timestamp() - last_seen_ts) if last_seen_ts is not none else none %}
              {% set offline = bermuda == 'not_home' and last_known in homeish and elapsed is not none and elapsed > offline_threshold %}
              {% if bermuda in ['unknown', 'unavailable'] %}
                {{ last_known }}
              {% elif offline %}
                {{ last_known }}
              {% elif normalized_area %}
                {{ normalized_area }}
              {% else %}
                {{ bermuda }}
              {% endif %}
            '';
            attributes = {
              bermuda_state = ''
                {% set tracker = states.device_tracker.joshs_nice_bike_bermuda_tracker %}
                {{ tracker.state if tracker else 'unknown' }}
              '';
              last_known_zone = ''
                {% set tracker = states.device_tracker.joshs_nice_bike_bermuda_tracker %}
                {% set bermuda = tracker.state if tracker else 'unknown' %}
                {% set last_known = this.attributes.last_known_zone | default('not_home') %}
                {% set area_attr = tracker.attributes.get('area') if tracker else none %}
                {% set normalized_area = area_attr | lower | replace(' ', '_') if area_attr is not none else none %}
                {% set homeish = ['garage', 'driveway', 'front_deck', 'home'] %}
                {% set last_seen_ts = this.attributes.last_seen_ts | default(none) %}
                {% set offline_threshold = 900 %}
                {% set elapsed = (now().timestamp() - last_seen_ts) if last_seen_ts is not none else none %}
                {% set offline = bermuda == 'not_home' and last_known in homeish and elapsed is not none and elapsed > offline_threshold %}
                {% if bermuda in ['unknown', 'unavailable'] %}
                  {{ last_known }}
                {% elif offline %}
                  {{ last_known }}
                {% elif normalized_area %}
                  {{ normalized_area }}
                {% else %}
                  {{ bermuda }}
                {% endif %}
              '';
              last_seen_ts = ''
                {% set tracker = states.device_tracker.joshs_nice_bike_bermuda_tracker %}
                {% set last_prev = this.attributes.last_seen_ts | default(none) %}
                {% if tracker %}
                  {% set raw_last = tracker.attributes.get('last_seen') %}
                  {% if raw_last %}
                    {{ as_timestamp(raw_last) }}
                  {% else %}
                    {{ as_timestamp(tracker.last_changed) }}
                  {% endif %}
                {% elif last_prev is not none %}
                  {{ last_prev }}
                {% else %}
                  {{ none }}
                {% endif %}
              '';
              last_seen = ''
                {% set ts = this.attributes.last_seen_ts | default(none) %}
                {% if ts is not none %}
                  {{ ts | timestamp_utc }}
                {% else %}
                  {{ none }}
                {% endif %}
              '';
              last_seen_seconds_ago = ''
                {% set ts = this.attributes.last_seen_ts | default(none) %}
                {% if ts is not none %}
                  {{ (now().timestamp() - ts) | round(0) }}
                {% else %}
                  {{ none }}
                {% endif %}
              '';
              last_source = ''
                {% set tracker = states.device_tracker.joshs_nice_bike_bermuda_tracker %}
                {% if tracker %}
                  {{ tracker.attributes.get('scanner') or tracker.attributes.get('source') or tracker.attributes.get('source_type') or "" }}
                {% else %}
                  {{ this.attributes.last_source | default("") }}
                {% endif %}
              '';
              offline = ''
                {% set tracker = states.device_tracker.joshs_nice_bike_bermuda_tracker %}
                {% set bermuda = tracker.state if tracker else 'unknown' %}
                {% set last_known = this.attributes.last_known_zone | default('not_home') %}
                {% set ts = this.attributes.last_seen_ts | default(none) %}
                {% set homeish = ['garage', 'driveway', 'front_deck', 'home'] %}
                {% set offline_threshold = 900 %}
                {% set elapsed = (now().timestamp() - ts) if ts is not none else none %}
                {{ bermuda == 'not_home' and last_known in homeish and elapsed is not none and elapsed > offline_threshold }}
              '';
              last_distance = ''
                {% set distance = states('sensor.joshs_nice_bike_distance') %}
                {% if distance not in ['unknown', 'unavailable'] %}
                  {{ distance | float }}
                {% else %}
                  {{ this.attributes.last_distance | default(none) }}
                {% endif %}
              '';
            };
          }
          {
            name = "Josh Nice Bike Last Seen";
            unique_id = "sensor_josh_nice_bike_last_seen";
            device_class = "timestamp";
            state = ''
              {% set ts = state_attr('sensor.josh_nice_bike_location','last_seen_ts') %}
              {% if ts is not none %}
                {{ ts | timestamp_utc }}
              {% else %}
                {{ none }}
              {% endif %}
            '';
          }
        ];
        binary_sensor = [
          {
            name = "Josh Nice Bike Offline";
            unique_id = "binary_sensor_josh_nice_bike_offline";
            device_class = "connectivity";
            state = "{{ 'on' if state_attr('sensor.josh_nice_bike_location','offline') else 'off' }}";
          }
        ];
      }
    ];
  };
  carPackage = {
    template = [
      {
        sensor = [
          {
            name = "Honda CRV Location";
            unique_id = "sensor_honda_crv_location";
            icon = "mdi:car";
            state = ''
              {% set tracker = states.device_tracker.bcpro_201403_bermuda_tracker %}
              {% set bermuda = tracker.state if tracker else 'unknown' %}
              {% set last_known = this.attributes.last_known_zone | default('not_home') %}
              {% set last_seen_prev = this.attributes.last_seen_ts | default(none) %}
              {% set area_attr = tracker.attributes.get('area') if tracker else none %}
              {% set normalized_area = area_attr | lower | replace(' ', '_') if area_attr is not none else none %}
              {% if tracker %}
                {% set raw_last = tracker.attributes.get('last_seen') %}
                {% if raw_last %}
                  {% set last_seen_ts = as_timestamp(raw_last) %}
                {% else %}
                  {% set last_seen_ts = as_timestamp(tracker.last_changed) %}
                {% endif %}
              {% else %}
                {% set last_seen_ts = last_seen_prev %}
              {% endif %}
              {% set homeish = ['garage', 'driveway', 'front_deck', 'home'] %}
              {% set offline_threshold = 900 %}
              {% set elapsed = (now().timestamp() - last_seen_ts) if last_seen_ts is not none else none %}
              {% set offline = bermuda == 'not_home' and last_known in homeish and elapsed is not none and elapsed > offline_threshold %}
              {% if bermuda in ['unknown', 'unavailable'] %}
                {{ last_known }}
              {% elif offline %}
                {{ last_known }}
              {% elif normalized_area %}
                {{ normalized_area }}
              {% else %}
                {{ bermuda }}
              {% endif %}
            '';
            attributes = {
              bermuda_state = ''
                {% set tracker = states.device_tracker.bcpro_201403_bermuda_tracker %}
                {{ tracker.state if tracker else 'unknown' }}
              '';
              last_known_zone = ''
                {% set tracker = states.device_tracker.bcpro_201403_bermuda_tracker %}
                {% set bermuda = tracker.state if tracker else 'unknown' %}
                {% set last_known = this.attributes.last_known_zone | default('not_home') %}
                {% set area_attr = tracker.attributes.get('area') if tracker else none %}
                {% set normalized_area = area_attr | lower | replace(' ', '_') if area_attr is not none else none %}
                {% set homeish = ['garage', 'driveway', 'front_deck', 'home'] %}
                {% set last_seen_ts = this.attributes.last_seen_ts | default(none) %}
                {% set offline_threshold = 900 %}
                {% set elapsed = (now().timestamp() - last_seen_ts) if last_seen_ts is not none else none %}
                {% set offline = bermuda == 'not_home' and last_known in homeish and elapsed is not none and elapsed > offline_threshold %}
                {% if bermuda in ['unknown', 'unavailable'] %}
                  {{ last_known }}
                {% elif offline %}
                  {{ last_known }}
                {% elif normalized_area %}
                  {{ normalized_area }}
                {% else %}
                  {{ bermuda }}
                {% endif %}
              '';
              last_seen_ts = ''
                {% set tracker = states.device_tracker.bcpro_201403_bermuda_tracker %}
                {% set last_prev = this.attributes.last_seen_ts | default(none) %}
                {% if tracker %}
                  {% set raw_last = tracker.attributes.get('last_seen') %}
                  {% if raw_last %}
                    {{ as_timestamp(raw_last) }}
                  {% else %}
                    {{ as_timestamp(tracker.last_changed) }}
                  {% endif %}
                {% elif last_prev is not none %}
                  {{ last_prev }}
                {% else %}
                  {{ none }}
                {% endif %}
              '';
              last_seen = ''
                {% set ts = this.attributes.last_seen_ts | default(none) %}
                {% if ts is not none %}
                  {{ ts | timestamp_utc }}
                {% else %}
                  {{ none }}
                {% endif %}
              '';
              last_seen_seconds_ago = ''
                {% set ts = this.attributes.last_seen_ts | default(none) %}
                {% if ts is not none %}
                  {{ (now().timestamp() - ts) | round(0) }}
                {% else %}
                  {{ none }}
                {% endif %}
              '';
              last_source = ''
                {% set tracker = states.device_tracker.bcpro_201403_bermuda_tracker %}
                {% if tracker %}
                  {{ tracker.attributes.get('scanner') or tracker.attributes.get('source') or tracker.attributes.get('source_type') or "" }}
                {% else %}
                  {{ this.attributes.last_source | default("") }}
                {% endif %}
              '';
              offline = ''
                {% set tracker = states.device_tracker.bcpro_201403_bermuda_tracker %}
                {% set bermuda = tracker.state if tracker else 'unknown' %}
                {% set last_known = this.attributes.last_known_zone | default('not_home') %}
                {% set ts = this.attributes.last_seen_ts | default(none) %}
                {% set homeish = ['garage', 'driveway', 'front_deck', 'home'] %}
                {% set offline_threshold = 900 %}
                {% set elapsed = (now().timestamp() - ts) if ts is not none else none %}
                {{ bermuda == 'not_home' and last_known in homeish and elapsed is not none and elapsed > offline_threshold }}
              '';
              last_distance = ''
                {% set distance = states('sensor.bcpro_201403_distance') %}
                {% if distance not in ['unknown', 'unavailable'] %}
                  {{ distance | float }}
                {% else %}
                  {{ this.attributes.last_distance | default(none) }}
                {% endif %}
              '';
            };
          }
          {
            name = "Honda CRV Last Seen";
            unique_id = "sensor_honda_crv_last_seen";
            device_class = "timestamp";
            state = ''
              {% set ts = state_attr('sensor.honda_crv_location','last_seen_ts') %}
              {% if ts is not none %}
                {{ ts | timestamp_utc }}
              {% else %}
                {{ none }}
              {% endif %}
            '';
          }
        ];
        binary_sensor = [
          {
            name = "Honda CRV Offline";
            unique_id = "binary_sensor_honda_crv_offline";
            device_class = "connectivity";
            state = "{{ 'on' if state_attr('sensor.honda_crv_location','offline') else 'off' }}";
          }
        ];
      }
    ];
  };
  leakSummaryLogic = ''
    {% set leak_entities = [
      'binary_sensor.leak_crawl_space',
      'binary_sensor.leak_main_bathroom',
      'binary_sensor.leak_kitchen_sink',
      'binary_sensor.leak_side_bathroom',
      'binary_sensor.leak_refrigerator',
      'binary_sensor.leak_attic',
      'binary_sensor.leak_shed',
      'binary_sensor.leak_laundry_room',
    ] %}
    {% set ack_map = {
      'binary_sensor.leak_crawl_space': 'input_boolean.leak_ack_crawl_space',
      'binary_sensor.leak_main_bathroom': 'input_boolean.leak_ack_main_bathroom',
      'binary_sensor.leak_kitchen_sink': 'input_boolean.leak_ack_kitchen_sink',
      'binary_sensor.leak_side_bathroom': 'input_boolean.leak_ack_side_bathroom',
      'binary_sensor.leak_refrigerator': 'input_boolean.leak_ack_refrigerator',
      'binary_sensor.leak_attic': 'input_boolean.leak_ack_attic',
      'binary_sensor.leak_shed': 'input_boolean.leak_ack_shed',
      'binary_sensor.leak_laundry_room': 'input_boolean.leak_ack_laundry',
    } %}
    {% set ns = namespace(active=0, unacked=0) %}
    {% for leak in leak_entities %}
      {% if is_state(leak, 'on') %}
        {% set ns.active = ns.active + 1 %}
        {% set ack = ack_map[leak] %}
        {% if ack is none or not is_state(ack, 'on') %}
          {% set ns.unacked = ns.unacked + 1 %}
        {% endif %}
      {% endif %}
    {% endfor %}
    {% set global_ack = is_state('input_boolean.leak_alert_acknowledged','on') %}
    {% set snoozed = is_state('timer.leak_alert_snooze','active') %}
  '';
  leaksPackage = {
    template = [
      {
        sensor = [
          {
            name = "Leak Alert Summary";
            unique_id = "sensor_leak_alert_summary";
            icon = "mdi:water-alert";
            state =
              leakSummaryLogic
              + ''
                {% if ns.active == 0 %}
                  No leaks
                {% elif snoozed %}
                  Snoozed
                {% elif global_ack or ns.unacked == 0 %}
                  Acknowledged
                {% else %}
                  Leak detected
                {% endif %}
              '';
            attributes = {
              status_key =
                leakSummaryLogic
                + ''
                  {% if ns.active == 0 %}
                    idle
                  {% elif snoozed %}
                    snoozed
                  {% elif global_ack or ns.unacked == 0 %}
                    acknowledged
                  {% else %}
                    active
                  {% endif %}
                '';
              active_count =
                leakSummaryLogic
                + ''
                  {{ ns.active }}
                '';
              unacked_count =
                leakSummaryLogic
                + ''
                  {{ ns.unacked }}
                '';
              actionable_ack =
                leakSummaryLogic
                + ''
                  {{ ns.unacked > 0 and not global_ack }}
                '';
              actionable_snooze =
                leakSummaryLogic
                + ''
                  {{ ns.active > 0 and not global_ack and not snoozed }}
                '';
              snoozed =
                leakSummaryLogic
                + ''
                  {{ snoozed }}
                '';
              global_ack =
                leakSummaryLogic
                + ''
                  {{ global_ack }}
                '';
              status_icon =
                leakSummaryLogic
                + ''
                  {% if ns.active == 0 %}
                    mdi:water-check
                  {% elif snoozed %}
                    mdi:alarm-check
                  {% elif global_ack or ns.unacked == 0 %}
                    mdi:check-circle
                  {% else %}
                    mdi:water-alert
                  {% endif %}
                '';
              status_color =
                leakSummaryLogic
                + ''
                  {% if ns.active == 0 %}
                    #1E88E5
                  {% elif snoozed %}
                    #1565C0
                  {% elif global_ack or ns.unacked == 0 %}
                    #2E7D32
                  {% else %}
                    #C62828
                  {% endif %}
                '';
              ack_label =
                leakSummaryLogic
                + ''
                  {% if ns.active == 0 %}
                    No leaks
                  {% elif ns.unacked > 0 and not global_ack %}
                    Acknowledge ({{ ns.unacked }})
                  {% else %}
                    ✓ Acknowledged
                  {% endif %}
                '';
              ack_icon =
                leakSummaryLogic
                + ''
                  {% if ns.active == 0 %}
                    mdi:check-circle-outline
                  {% elif ns.unacked > 0 and not global_ack %}
                    mdi:check-all
                  {% else %}
                    mdi:check-circle
                  {% endif %}
                '';
              ack_background =
                leakSummaryLogic
                + ''
                  {% if ns.unacked > 0 and not global_ack %}
                    rgba(229, 115, 115, 0.35)
                  {% elif ns.active == 0 %}
                    rgba(120, 144, 156, 0.20)
                  {% else %}
                    rgba(76, 175, 80, 0.30)
                  {% endif %}
                '';
              ack_color =
                leakSummaryLogic
                + ''
                  {% if ns.unacked > 0 and not global_ack %}
                    #C62828
                  {% elif ns.active == 0 %}
                    #546E7A
                  {% else %}
                    #2E7D32
                  {% endif %}
                '';
              snooze_label =
                leakSummaryLogic
                + ''
                  {% if ns.active == 0 %}
                    No leaks
                  {% elif snoozed %}
                    {% set remaining = state_attr('timer.leak_alert_snooze','remaining') %}
                    Snoozed {{ remaining if remaining else "" }}
                  {% else %}
                    Snooze 15 m (hold 60 m)
                  {% endif %}
                '';
              snooze_icon =
                leakSummaryLogic
                + ''
                  {% if snoozed %}
                    mdi:alarm-check
                  {% else %}
                    mdi:alarm-snooze
                  {% endif %}
                '';
              snooze_background =
                leakSummaryLogic
                + ''
                  {% if snoozed %}
                    rgba(129, 199, 245, 0.35)
                  {% elif ns.active > 0 and not global_ack %}
                    rgba(144, 202, 249, 0.25)
                  {% else %}
                    rgba(120, 144, 156, 0.20)
                  {% endif %}
                '';
              snooze_color =
                leakSummaryLogic
                + ''
                  {% if snoozed %}
                    #1565C0
                  {% elif ns.active > 0 and not global_ack %}
                    #0D47A1
                  {% else %}
                    #546E7A
                  {% endif %}
                '';
              snooze_remaining =
                leakSummaryLogic
                + ''
                  {{ state_attr('timer.leak_alert_snooze','remaining') or "" }}
                '';
              snooze_finishes_at =
                leakSummaryLogic
                + ''
                  {{ state_attr('timer.leak_alert_snooze','finishes_at') or "" }}
                '';
            };
          }
        ];
      }
    ];
  };
  blePassthrough = pkgs.fetchFromGitHub {
    owner = "iHost-Open-Source-Project";
    repo = "ble_passthrough";
    rev = "79d807f1bdbc46a8358869cd283ca85e93b20c9c";
    sha256 = "sha256-hUALGWg22QYCqZk1J4kMy2fJtbOOve4930LzNx+mPGQ=";
  };
in {
  services.home-assistant = {
    enable = true;
    package = pkgs.home-assistant;

    # Add extra Python packages for integrations that need them
    extraPackages = python3Packages:
      with python3Packages; [
        grpcio
        grpcio-status
        grpcio-reflection
        grpcio-tools
        gtts # Google Text-to-Speech
        pyatv # Apple TV integration
        pyheos # HEOS (Denon/Marantz) integration
        wyoming # Wyoming protocol for voice services (Piper TTS)
        aiogithubapi # Required for HACS
        zlib-ng # Optimized compression for aiohttp_fast_zlib
      ];

    # Custom components (like Nest Protect)
    customComponents = with pkgs.home-assistant-custom-components; [
      nest_protect
    ];

    # Custom Lovelace cards
    customLovelaceModules = with pkgs.home-assistant-custom-lovelace-modules; [
      card-mod # CSS styling for cards
    ];

    extraComponents = [
      # Core functionality
      "default_config" # Includes most common integrations
      "bluetooth" # Core Bluetooth stack for proxies, iBeacons
      "met" # Weather (required for onboarding)
      "radio_browser" # Radio stations
      "application_credentials" # OAuth credential management for self-hosted
      "ffmpeg" # Media processing (required for Nest and cameras)

      # Smart devices
      "hue" # Philips Hue lights
      "lutron_caseta" # Lutron Caseta switches and dimmers
      "homekit_controller" # Connect HomeKit devices locally (including ecobee)
      "zeroconf" # Network discovery for HomeKit and other devices
      "zwave_js" # Z-Wave via Z-Wave JS UI on bluedesert
      "miele" # Miele appliances (dishwasher)
      "lg_thinq" # LG ThinQ washer/dryer (requires LG account)
      "home_connect" # Bosch/Siemens Home Connect appliances
      "nest" # Nest Protect smoke/CO detectors and thermostats
      "sonos" # Sonos speakers and sound system
      "unifi" # UniFi network devices (access points, switches, controller)
      "spotify" # Spotify media playback and control
      "tailwind" # Tailwind garage door controllers
      "mqtt" # MQTT (if you add it later)

      # Local media integration
      "jellyfin" # Your Jellyfin server
      "webostv" # LG WebOS TV control
      "denonavr" # Denon/Marantz AVR receivers
      "radarr" # Movie collection manager
      "sonarr" # TV show collection manager
      "sabnzbd" # SABnzbd downloader (running in podman)

      # System monitoring
      "systemmonitor" # Monitor ultraviolet's resources
      "uptime"
      "command_line" # Run shell commands for monitoring

      # Network services
      "tailscale" # Tailscale VPN status and control

      # Additional services
      "todoist"

      # Voice and audio
      "piper" # Local text-to-speech (supports custom voices like GlaDOS)
      "wyoming" # Protocol for voice services integration
      "ibeacon" # Detect iBeacon button broadcasts
      "esphome"

      # Mobile app support
      "mobile_app" # For Home Assistant companion app
      "webhook" # For app communications

      # Automation helpers
      "input_boolean"
      "input_button"
      "input_datetime"
      "input_number"
      "input_select"
      "input_text"
      "timer"
      "counter"
      "schedule"
    ];

    config = {
      # Basic configuration
      default_config = {};

      homeassistant = {
        name = "Home";
        # Location is loaded from secrets.yaml to keep it out of git
        latitude = "!secret latitude";
        longitude = "!secret longitude";
        elevation = "!secret elevation";
        unit_system = "us_customary"; # Use Fahrenheit, miles, etc.
        time_zone = "America/Los_Angeles";
        currency = "USD";
        country = "US";
        # External access via Cloudflare Tunnel
        external_url = "https://home.husbuddies.gay";
        # Use LAN-reachable IP so speakers (e.g., Sonos) can fetch TTS audio
        internal_url = "http://172.31.0.200:8123";

        packages = {
          keychain_button = keychainPackage;
          bike = bikePackage;
          car = carPackage;
          leaks = leaksPackage;
        };

        # Multi-factor authentication configuration
        auth_mfa_modules = [
          {
            # Primary MFA: Time-based One-Time Password (TOTP)
            # Use with Google Authenticator, Authy, 1Password, etc.
            type = "totp";
            name = "Authenticator app";
          }
        ];

        # Entity customizations (friendly names for clarity in alerts)
        customize = {
          "binary_sensor.leak_laundry_room".friendly_name = "Laundry Room Leak";
          "binary_sensor.leak_shed".friendly_name = "Shed Leak";
          "binary_sensor.shed_door".friendly_name = "Shed Door";
          "binary_sensor.office_deck_window".friendly_name = "Office Deck Window";
          "binary_sensor.front_door".friendly_name = "Front Door";
          "binary_sensor.kitchen_door".friendly_name = "Kitchen Door";
          "binary_sensor.back_deck_door".friendly_name = "Back Deck Door";
          "binary_sensor.back_deck_side_door".friendly_name = "Back Deck Side Door";
          "binary_sensor.front_deck_sliding_door".friendly_name = "Front Deck Sliding Door";
          "binary_sensor.office_door".friendly_name = "Office Door";
          "binary_sensor.front_deck_left_window".friendly_name = "Front Deck Left Window";
          "binary_sensor.front_deck_right_window".friendly_name = "Front Deck Right Window";
          "binary_sensor.main_bedroom_side_window".friendly_name = "Main Bedroom Side Window";
        };
      };

      # Define the home zone with a smaller radius (in meters)
      zone = [
        {
          name = "Home";
          latitude = "!secret latitude";
          longitude = "!secret longitude";
          radius = 50; # 50 meters (~164 feet) - adjust as needed
          icon = "mdi:home";
        }
      ];

      # Enable the web interface
      http = {
        server_host = "0.0.0.0"; # Listen on all interfaces (needed for proxies)
        # Narrowed from the /24 to just localhost: Caddy (the only reverse
        # proxy in front of HA) runs on this same host, so nothing else
        # legitimately sends X-Forwarded-* headers.
        trusted_proxies = [
          "127.0.0.1"
          "::1"
        ];
        use_x_forwarded_for = true;
        ip_ban_enabled = true;
        login_attempts_threshold = 5;
      };

      # Configure recorder for history (30 days default)
      recorder = {
        purge_keep_days = 30;
        exclude = {
          domains = [
            "automation"
            "updater"
          ];
          entity_globs = [
            "sensor.weather_*"
          ];
        };
      };

      # Z-Wave JS configuration to connect to bluedesert
      zwave_js = {
        # This will be configured through the UI
        # URL: ws://bluedesert:3000 or ws://172.31.0.201:3000
      };

      # Frontend themes
      frontend = {
        themes = "!include_dir_merge_named themes";
      };

      ble_passthrough = {};

      # Lovelace configuration
      #
      # `lovelace.mode` is deprecated (nixpkgs' home-assistant module warns:
      # removed upstream in HA 2026.8, currently pinned to 2026.6.4). Its
      # replacement isn't a doc-guessed shape — it's read straight out of
      # this pin's homeassistant/components/lovelace/__init__.py: when
      # `mode: yaml` was set, HA's own deprecation shim auto-added exactly
      # this `dashboards.lovelace` entry (title/icon/show_in_sidebar/
      # require_admin match its hardcoded defaults) and split resource
      # loading out into `resource_mode`. This is that same shape written
      # explicitly, so behavior for the existing dashboards is unchanged.
      lovelace = {
        resource_mode = "yaml";
        dashboards.lovelace = {
          mode = "yaml";
          filename = "ui-lovelace.yaml";
          title = "Overview";
          icon = "mdi:view-dashboard";
          show_in_sidebar = true;
          require_admin = false;
        };
        resources = [
          {
            url = "/hacsfiles/Bubble-Card/bubble-card.js";
            type = "module";
          }
          {
            # Prevent pop-up content from flashing or misinitializing; improves pop-up behavior
            url = "/hacsfiles/Bubble-Card/bubble-pop-up-fix.js";
            type = "module";
          }
          {
            url = "/hacsfiles/lovelace-auto-entities/auto-entities.js";
            type = "module";
          }
          {
            url = "/local/nixos-lovelace-modules/card-mod.js";
            type = "module";
          }
        ];
      };

      # Enable Browser Mod integration for dynamic popups
      browser_mod = {};

      # Controls for leak alert TTS behavior
      input_boolean = {
        josh_keychain_button_pressed = {
          name = "Josh Keychain Button Pressed";
          icon = "mdi:gesture-double-tap";
          initial = false;
        };
        justin_keychain_button_pressed = {
          name = "Justin Keychain Button Pressed";
          icon = "mdi:gesture-double-tap";
          initial = false;
        };
        leak_alert_tts_enabled = {
          name = "Leak alert speech";
          icon = "mdi:volume-high";
          initial = true;
        };
        leak_alert_acknowledged = {
          name = "Leak alert acknowledged";
          icon = "mdi:check-circle";
          initial = false;
        };
        # Per-sensor acknowledgements to silence individual leak repeats
        leak_ack_crawl_space = {
          name = "Ack leak: Crawl Space";
          icon = "mdi:check-circle";
          initial = false;
        };
        leak_ack_main_bathroom = {
          name = "Ack leak: Main Bathroom";
          icon = "mdi:check-circle";
          initial = false;
        };
        leak_ack_kitchen_sink = {
          name = "Ack leak: Kitchen Sink";
          icon = "mdi:check-circle";
          initial = false;
        };
        leak_ack_side_bathroom = {
          name = "Ack leak: Side Bathroom";
          icon = "mdi:check-circle";
          initial = false;
        };
        leak_ack_refrigerator = {
          name = "Ack leak: Refrigerator";
          icon = "mdi:check-circle";
          initial = false;
        };
        leak_ack_attic = {
          name = "Ack leak: Attic";
          icon = "mdi:check-circle";
          initial = false;
        };
        leak_ack_laundry = {
          name = "Ack leak: Laundry";
          icon = "mdi:check-circle";
          initial = false;
        };
        leak_ack_shed = {
          name = "Ack leak: Shed";
          icon = "mdi:check-circle";
          initial = false;
        };
        nice_bike_should_open = {
          name = "Nice Bike Should Open Garage";
          icon = "mdi:bike";
          initial = false;
        };
        honda_crv_should_open = {
          name = "Honda CRV Should Open Garage";
          icon = "mdi:car";
          initial = false;
        };
      };

      input_number = {
        leak_alert_tts_volume = {
          name = "Leak alert TTS volume";
          icon = "mdi:volume-medium";
          unit_of_measurement = "";
          min = 0.0;
          max = 1.0;
          step = 0.05;
          mode = "slider";
          initial = 0.35;
        };
      };

      input_button = {
        leak_acknowledge = {
          name = "Acknowledge leak";
          icon = "mdi:check";
        };
        leak_snooze_15 = {
          name = "Snooze leak 15m";
          icon = "mdi:alarm-snooze";
        };
        leak_snooze_60 = {
          name = "Snooze leak 60m";
          icon = "mdi:alarm-snooze";
        };
      };

      input_select = {
        living_room_popup_view = {
          name = "Living Room Popup View";
          icon = "mdi:view-dashboard";
          options = [
            "control"
            "scenes"
            "lights"
          ];
          initial = "control";
        };
        main_bedroom_popup_view = {
          name = "Main Bedroom Popup View";
          icon = "mdi:view-dashboard";
          options = [
            "control"
            "scenes"
            "lights"
          ];
          initial = "control";
        };
      };

      timer = {
        leak_alert_snooze = {
          name = "Leak alert snooze";
          duration = "00:15:00";
        };
      };

      # Logging
      logger = {
        default = "warning";
        logs = {
          "homeassistant.components.lovelace" = "debug";
          "homeassistant.components.frontend" = "debug";
          "homeassistant.components.websocket_api" = "debug";
          "homeassistant.components.zwave_js" = "info";
          "homeassistant.components.sonos" = "info"; # Debug Sonos discovery
          "homeassistant.components.ssdp" = "warning"; # Reduce noise
        };
      };

      # Sonos configuration - Manual discovery for Sonos Move
      sonos = {
        media_player = {
          hosts = [
            "172.31.0.32" # Sonos Move
          ];
        };
      };

      # Miele configuration (for self-hosted OAuth)
      # You'll need to get client_id and client_secret from Miele developer portal
      # miele = {
      #   client_id = "!secret miele_client_id";
      #   client_secret = "!secret miele_client_secret";
      # };

      # Automation engine (keep automations in UI for easy editing)
      # Use Git-tracked, directory-merged automations
      automation = "!include_dir_merge_list automations";
      script = "!include scripts.yaml";
      scene = "!include scenes.yaml";
    };

    # Make configuration writable so you can edit from the UI
    configWritable = true;

    # Configure directory for additional YAML files
    configDir = "/var/lib/hass";

    # Open firewall port (only localhost, Caddy handles external)
    openFirewall = false;
  };

  # Add Home Assistant to Caddy reverse proxy
  services.caddy.virtualHosts."homeassistant.home.husbuddies.gay" = {
    extraConfig = ''
      reverse_proxy localhost:8123 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
      }
      import cloudflare
    '';
  };

  systemd = {
    # Create necessary directories and files
    tmpfiles.rules = [
      "d /var/lib/hass/themes 0755 hass hass -"
      "d /var/lib/hass/custom_components 0755 hass hass -"
      "d /var/lib/hass/www 0755 hass hass -"
      "d /var/lib/hass/dashboards 0755 hass hass -"
      "d /var/lib/hass/packages 0755 hass hass -"
    ];

    services = {
      # Setup HACS and secrets file
      # We use a separate service to install HACS to avoid systemd sandboxing issues
      home-assistant-setup-hacs = {
        description = "Setup HACS for Home Assistant";
        wantedBy = ["multi-user.target"];
        before = ["home-assistant.service"];

        serviceConfig = {
          Type = "oneshot";
          User = "hass";
          Group = "hass";
          RemainAfterExit = true;
        };

        script = ''
          set -e

          # Ensure custom_components directory exists
          mkdir -p /var/lib/hass/custom_components

          # Download and install HACS if not present or outdated
          if [ ! -f /var/lib/hass/custom_components/hacs/manifest.json ]; then
            echo "Installing HACS..."

            # Change to custom_components directory (following official script)
            cd /var/lib/hass/custom_components

            # Download latest HACS release
            ${pkgs.wget}/bin/wget -q "https://github.com/hacs/integration/releases/latest/download/hacs.zip"

            # Remove old HACS if it exists
            if [ -d "hacs" ]; then
              rm -rf hacs
            fi

            # Create HACS directory
            mkdir hacs

            # Unpack HACS (exactly like official script)
            ${pkgs.unzip}/bin/unzip -q hacs.zip -d hacs

            # Cleanup
            rm -f hacs.zip

            echo "HACS installation complete"
          else
            echo "HACS already installed"
          fi
        '';
      };

      # Dashboard files are handled directly in preStart script

      # Setup secrets file on startup and sync Lovelace YAML
      home-assistant = {
        preStart = lib.mkAfter ''
              # Copy secrets file if it doesn't exist
              if [ ! -f /var/lib/hass/secrets.yaml ]; then
                cp /etc/hass-secrets.yaml /var/lib/hass/secrets.yaml
                chown hass:hass /var/lib/hass/secrets.yaml
                chmod 600 /var/lib/hass/secrets.yaml
                echo "Created secrets.yaml - please edit it with your actual values"
              fi

              # Deploy dashboard structure from the Nix config on every start
              rm -rf /var/lib/hass/dashboards
              mkdir -p /var/lib/hass/dashboards
              cp -r ${../../home-assistant/dashboards}/* /var/lib/hass/dashboards/
              find /var/lib/hass/dashboards -type f -exec chmod 644 {} \;
              find /var/lib/hass/dashboards -type d -exec chmod 755 {} \;
              # Files already have correct ownership since service runs as hass user
              # Create symlink for main dashboard file
              ln -sf /var/lib/hass/dashboards/ui-lovelace.yaml /var/lib/hass/ui-lovelace.yaml

              # Sync Git-managed automations directory (merged list include)
              rm -rf /var/lib/hass/automations
              mkdir -p /var/lib/hass/automations
          ${lib.optionalString (builtins.pathExists ../../home-assistant/automations) ''
            cp -r ${../../home-assistant/automations}/* /var/lib/hass/automations/
            find /var/lib/hass/automations -type f -exec chmod 644 {} \;
            find /var/lib/hass/automations -type d -exec chmod 755 {} \;
          ''}
          ${lib.optionalString (!(builtins.pathExists ../../home-assistant/automations)) ''
            echo "No automations directory found in Nix repo; skipping copy"
          ''}

              # Sync Git-managed blueprints directory
              rm -rf /var/lib/hass/blueprints
              mkdir -p /var/lib/hass/blueprints
          ${lib.optionalString (builtins.pathExists ../../home-assistant/blueprints) ''
            cp -r ${../../home-assistant/blueprints}/* /var/lib/hass/blueprints/
            find /var/lib/hass/blueprints -type f -exec chmod 644 {} \;
            find /var/lib/hass/blueprints -type d -exec chmod 755 {} \;
          ''}
          ${lib.optionalString (!(builtins.pathExists ../../home-assistant/blueprints)) ''
            echo "No blueprints directory found in Nix repo; skipping copy"
          ''}

              # Deploy BLE passthrough custom component from Nix store each start
              mkdir -p /var/lib/hass/custom_components
              rm -rf /var/lib/hass/custom_components/ble_passthrough
              cp -r ${blePassthrough}/custom_components/ble_passthrough /var/lib/hass/custom_components/
              find /var/lib/hass/custom_components/ble_passthrough -type f -exec chmod 644 {} \;
              find /var/lib/hass/custom_components/ble_passthrough -type d -exec chmod 755 {} \;
        '';

        # Ensure Home Assistant restarts when dashboard sources change,
        # so the preStart sync copies new/updated YAML (e.g., new popups)
        restartTriggers = [
          ../../home-assistant/dashboards
          ../../home-assistant/automations
          ../../home-assistant/blueprints
        ];
      };

      # Backup service for Home Assistant
      home-assistant-backup = {
        description = "Backup Home Assistant configuration to NAS";
        after = [
          "home-assistant.service"
          "mnt-backups.mount"
        ];
        requires = ["mnt-backups.mount"];

        path = with pkgs; [
          coreutils
          rsync
          util-linux # for mountpoint and logger
          findutils
          gnused
        ];

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          # Use the backup script we've created
          # For scheduled backups, don't pass a label argument
          ExecStart = "${ha-backup-script}/bin/backup-ha";
        };
      };

      # Restore service for Home Assistant
      home-assistant-restore = {
        description = "Restore Home Assistant configuration from NAS backup";
        after = ["mnt-backups.mount"];
        requires = ["mnt-backups.mount"];
        before = ["home-assistant.service"];

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          RemainAfterExit = false;
          ExecStart = pkgs.writeShellScript "ha-restore" ''
                set -e

                BACKUP_DIR="/mnt/backups/home-assistant"
            RESTORE_DIR="/var/lib/hass"

            # Parse arguments
            BACKUP_NAME="''${1:-latest}"

            # Determine which backup to restore
            if [ "$BACKUP_NAME" = "latest" ]; then
              if [ -L "$BACKUP_DIR/latest" ]; then
                BACKUP_PATH="$BACKUP_DIR/latest"
                echo "Restoring from latest backup: $(readlink -f "$BACKUP_PATH")"
              else
                echo "Error: No 'latest' symlink found. Please specify a backup name."
                echo "Available backups:"
                ls -1d "$BACKUP_DIR"/backup-* 2>/dev/null | sed 's|.*/||' || echo "No backups found"
                exit 1
              fi
            elif [ -d "$BACKUP_DIR/$BACKUP_NAME" ]; then
              BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
              echo "Restoring from backup: $BACKUP_NAME"
            else
              echo "Error: Backup '$BACKUP_NAME' not found"
              echo "Available backups:"
              ls -1d "$BACKUP_DIR"/backup-* 2>/dev/null | sed 's|.*/||' || echo "No backups found"
              exit 1
            fi

            # Safety check - confirm if Home Assistant is running
            if systemctl is-active --quiet home-assistant.service; then
              echo "WARNING: Home Assistant is currently running!"
              echo "It's recommended to stop it before restoring:"
              echo "  sudo systemctl stop home-assistant.service"
              echo ""
              echo "Proceed anyway? This might cause issues. (y/N)"
              read -r response
              if [[ ! "$response" =~ ^[Yy]$ ]]; then
                echo "Restore cancelled"
                exit 0
              fi
            fi

            # Create backup of current config before restoring
            if [ -d "$RESTORE_DIR" ] && [ "$(ls -A "$RESTORE_DIR")" ]; then
              SAFETY_BACKUP="/var/lib/hass-backup-before-restore-$(date +%Y%m%d-%H%M%S)"
              echo "Creating safety backup of current config at $SAFETY_BACKUP"
              ${pkgs.rsync}/bin/rsync -rlptD "$RESTORE_DIR/" "$SAFETY_BACKUP/"
            fi

            # Ensure target directory exists
            mkdir -p "$RESTORE_DIR"

            # Perform the restore
            echo "Restoring configuration from $BACKUP_PATH..."
            ${pkgs.rsync}/bin/rsync -rlptDv --delete \
              --exclude='home-assistant_v2.db-shm' \
              --exclude='home-assistant_v2.db-wal' \
              --exclude='*.log' \
              --exclude='*.log.*' \
              "$BACKUP_PATH/" "$RESTORE_DIR/"

            # Fix ownership
            chown -R hass:hass "$RESTORE_DIR"

            echo ""
            echo "✅ Restore completed successfully!"
            echo ""
                echo "Next steps:"
                echo "1. Start Home Assistant: sudo systemctl start home-assistant.service"
                echo "2. Check the logs: sudo journalctl -fu home-assistant.service"
                echo "3. Access the UI at https://home.husbuddies.gay"
                echo ""
                if [ -n "$SAFETY_BACKUP" ]; then
                  echo "Safety backup preserved at: $SAFETY_BACKUP"
                  echo "You can remove it once everything is working: sudo rm -rf $SAFETY_BACKUP"
                fi
          '';
        };
      };
    };

    # Timer to run backup daily at 3 AM
    timers.home-assistant-backup = {
      description = "Daily Home Assistant backup timer";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-* 03:00:00"; # Daily at 3 AM
        Persistent = true; # Run backup if system was off at scheduled time
        RandomizedDelaySec = "10m"; # Add some randomness to prevent exact time conflicts
      };
    };
  };

  # Create a secrets.yaml template for Home Assistant
  # This file can be edited after deployment to add your actual secrets
  environment.etc."hass-secrets.yaml" = {
    mode = "0600";
    user = "hass";
    text = ''
      # Home Assistant Secrets File
      # IMPORTANT: Edit this file at /var/lib/hass/secrets.yaml after deployment
      # with your actual location and API keys

      # Location data - MUST UPDATE with your actual location
      # Find your coordinates at https://www.latlong.net/
      latitude: 0.0
      longitude: 0.0
      elevation: 0

      # Z-Wave JS WebSocket URL (update if using different host/port)
      zwave_js_url: ws://172.31.0.201:3000

      # API Keys (add as needed)
      # ecobee_api_key: your-ecobee-api-key
      # openweathermap_api_key: your-openweathermap-key

      # Notification servers
      ntfy_server: http://172.31.0.201:8093
      # Use random strings for topics for security
      ntfy_topic_alerts: home-alerts-CHANGEME
      ntfy_topic_water: water-sensors-CHANGEME
      ntfy_topic_security: door-sensors-CHANGEME
    '';
  };

  # Create convenient restore command
  environment.systemPackages = with pkgs; [
    ha-backup-script # Add the backup script to PATH
    hassCliWrapped # hass-cli with auto server/token
    jq # JSON processor for API responses
    yamllint # YAML linter for configuration validation
    (writeShellScriptBin "ha-restore" ''
      # Home Assistant Restore Tool
      # Usage: ha-restore [backup-name|latest]
      #   latest (default) - Restore the most recent backup
      #   backup-20250902-225915 - Restore specific backup by name
      #   list - Show available backups

      set -e

      BACKUP_DIR="/mnt/backups/home-assistant"

      case "''${1:-latest}" in
        list|--list|-l)
          echo "Available Home Assistant backups:"
          echo ""
          if [ -L "$BACKUP_DIR/latest" ]; then
            echo "  latest -> $(basename "$(readlink -f "$BACKUP_DIR/latest")")"
            echo ""
          fi
          ls -1dt "$BACKUP_DIR"/backup-* 2>/dev/null | while read -r backup; do
            size=$(${pkgs.coreutils}/bin/du -sh "$backup" | cut -f1)
            date=$(basename "$backup" | sed 's/backup-//')
            echo "  $(basename "$backup") ($size)"
          done || echo "No backups found"
          ;;
        *)
          # Stop HA if running
          if systemctl is-active --quiet home-assistant.service; then
            echo "Stopping Home Assistant for restore..."
            sudo systemctl stop home-assistant.service
          fi

          # Run the restore
          sudo systemctl start home-assistant-restore.service "''${1:-latest}"

          # Follow the logs
          sudo journalctl -u home-assistant-restore.service -f --no-pager
          ;;
      esac
    '')
  ];

  # Note: After deploying, you'll need to:
  # 1. UPDATE LOCATION: Edit /var/lib/hass/secrets.yaml with your actual latitude/longitude
  # 2. Access Home Assistant at https://homeassistant.home.husbuddies.gay
  # 3. Complete the onboarding process
  # 4. Update location in UI: Settings -> System -> General
  # 5. Configure HACS:
  #    - Settings -> Devices & Services -> Add Integration -> HACS
  #    - Authorize with GitHub (create GitHub account if needed)
  #    - Enable experimental features if desired
  #    - Bubble Card should already be installed and ready to use
  # 6. Add integrations:
  #    - Z-Wave JS: URL ws://bluedesert:3000 or ws://172.31.0.201:3000
  #    - Philips Hue: Will auto-discover or add manually
  #    - Ecobee: Use the cloud integration with OAuth
  #    - Jellyfin: Server at http://localhost:8096
  # 7. Install the companion app on your phone
  # 8. Set up ntfy in automations for push notifications
  # 9. Install additional HACS components as needed:
  #     - Mushroom Cards (mobile-optimized UI)
  #     - Button Card (advanced customization)
  #     - Card-mod (styling)
  #     - Mini Graph Card (data visualization)
}
