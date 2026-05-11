# Declarative OBS Studio — every config file is a read-only symlink
# into /nix/store. Any change to scenes, the WebSocket port, plugin
# set, etc. flows through `update`; OBS itself can never persist a
# mutation on disk. When OBS tries to save on shutdown (window
# geometry, last-active scene, etc.) the write fails and is dropped —
# that failure is the desired behavior: any UI-induced state that
# wants to survive a session has to be declared here in nix instead.
#
# To reset to the canonical state at any time:
#   rm -rf ~/.config/obs-studio
#   update
#
# Scope of this module:
#
# - The OBS binary itself, with the lazycam-required plugins
#   (background-removal for blur, obs-face-tracker for the V1 Center
#   Stage analog, obs-websocket built into OBS 28+ so no plugin
#   needed there).
# - A "lazycam" scene collection with Active (Video Capture Device on
#   /dev/video0) and Standby (solid-black color source) scenes — the
#   pair the lazycam daemon expects (--scene-active / --scene-standby).
# - global.ini configuring the WebSocket server on 127.0.0.1:4455 with
#   auth disabled (loopback-only contract; see ~/Personal/lazycam's
#   switcher.requireLoopback enforcement) and pointing OBS at the
#   lazycam collection as the default.
#
# Out of scope (for now):
#
# - Profile config (recording paths, encoder settings) — OBS creates a
#   default writable profile dir on first launch; leave imperative
#   until we have a reason to declare it.
# - plugin_config/ — same story.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.obsLazycam;

  # Stable UUIDs so re-applying the module across rebuilds produces
  # byte-identical config files (avoids OBS-internal cache churn on
  # every `update`).
  uuid = {
    sceneStandby = "11111111-1111-1111-1111-111111111111";
    sceneActive = "22222222-2222-2222-2222-222222222222";
    webcam = "33333333-3333-3333-3333-333333333333";
    standbyBackground = "44444444-4444-4444-4444-444444444444";
  };

  # Default scene-item transform — top-left origin, scale 1.0, no
  # crop or bounding. align=5 is OBS's ALIGN_LEFT|ALIGN_TOP.
  defaultItemTransform = {
    visible = true;
    locked = false;
    rot = 0.0;
    scale = {
      x = 1.0;
      y = 1.0;
    };
    align = 5;
    bounds_type = 0;
    bounds_align = 0;
    bounds_crop = false;
    bounds = {
      x = 0.0;
      y = 0.0;
    };
    crop_left = 0;
    crop_top = 0;
    crop_right = 0;
    crop_bottom = 0;
    pos = {
      x = 0.0;
      y = 0.0;
    };
    scale_filter = "disable";
    blend_method = "default";
    blend_type = "normal";
    show_transition = {
      duration = 0;
      id = "cut_transition";
    };
    hide_transition = {
      duration = 0;
      id = "cut_transition";
    };
    private_settings = {};
    group_item_backup = false;
  };

  lazycamSceneCollection = {
    name = "lazycam";
    current_scene = "Standby";
    current_program_scene = "Standby";
    scene_order = [
      {name = "Standby";}
      {name = "Active";}
    ];

    sources = [
      # The real webcam source — pipewire-camera-source NOT v4l2_input.
      #
      # OBS's v4l2_input plugin has no .show/.hide hooks (verified in
      # plugins/linux-v4l2/v4l2-input.c — only .create / .destroy /
      # .update). That means it holds the camera file descriptor open
      # for the entire lifetime of the source, regardless of which
      # scene is the program scene. With v4l2_input, the hardware LED
      # stays on while OBS is running, period — defeating lazycam's
      # entire reason for existing.
      #
      # The PipeWire camera source (plugins/linux-pipewire/camera-
      # portal.c) DOES implement .show/.hide; they delegate to
      # obs_pipewire_stream_show/hide which releases the underlying
      # PipeWire stream and the kernel camera handle. LED follows
      # show-state — the desired behavior.
      #
      # device_id is the PipeWire node name (stable per camera + USB
      # port + PCI host controller). Find yours via:
      #   pw-cli ls Node | grep -B1 -A8 'media.class = "Video/Source"'
      # We require it as an explicit option rather than defaulting so
      # this module is reusable on any desktop host.
      {
        id = "pipewire-camera-source";
        versioned_id = "pipewire-camera-source";
        uuid = uuid.webcam;
        name = "Real Webcam";
        settings = {
          device_id = cfg.cameraDeviceId;
          # format and framerate are JSON-encoded strings inside the
          # parent JSON (the camera-portal.c parses them via
          # obs_data_create_from_json). Without both, the PipeWire
          # stream's format negotiation fails with "no more input
          # formats" — the stream never establishes and OBS shows
          # nothing in the preview.
          format = builtins.toJSON cfg.cameraFormat;
          framerate = builtins.toJSON {
            framerate = {
              numerator = cfg.cameraFramerate.numerator;
              denominator = cfg.cameraFramerate.denominator;
            };
          };
        };
        sync = 0;
        muted = false;
        private_settings = {};
        filters = [];
        hotkeys = {};
      }

      # Standby placeholder: opaque black at canvas size. The
      # important invariant is that THIS source holds no /dev/video0
      # handle — when OBS's program scene is Standby, the camera
      # source is not active and the hardware LED is off.
      #
      # color is ARGB packed into uint32: 0xFF000000 = opaque black.
      {
        id = "color_source_v3";
        versioned_id = "color_source_v3";
        uuid = uuid.standbyBackground;
        name = "Standby Background";
        settings = {
          color = 4278190080;
          width = 1920;
          height = 1080;
        };
        sync = 0;
        muted = false;
        private_settings = {};
        filters = [];
        hotkeys = {};
      }

      # Standby scene: only contains the color source.
      {
        id = "scene";
        versioned_id = "scene";
        uuid = uuid.sceneStandby;
        name = "Standby";
        settings = {
          id_counter = 1;
          custom_size = false;
          items = [
            (defaultItemTransform
              // {
                name = "Standby Background";
                source_uuid = uuid.standbyBackground;
                id = 1;
              })
          ];
        };
        sync = 0;
        muted = false;
        private_settings = {};
        filters = [];
        hotkeys = {};
      }

      # Active scene: only the webcam source. The face-tracker filter
      # would be a per-source filter living in this source's `filters`
      # array — leaving it empty in V1 so the canonical scene loads
      # cleanly; add filters declaratively as we shape the face
      # pipeline.
      {
        id = "scene";
        versioned_id = "scene";
        uuid = uuid.sceneActive;
        name = "Active";
        settings = {
          id_counter = 1;
          custom_size = false;
          items = [
            (defaultItemTransform
              // {
                name = "Real Webcam";
                source_uuid = uuid.webcam;
                id = 1;
              })
          ];
        };
        sync = 0;
        muted = false;
        private_settings = {};
        filters = [];
        hotkeys = {};
      }
    ];

    # Top-level collection fields OBS expects. The version stamp matches
    # the OBS 28+ scene-format generation; OBS will accept this as long
    # as the JSON parses.
    saved_projectors = [];
    transitions = [];
    transition_duration = 300;
    preview_locked = false;
    scaling_enabled = false;
    scaling_level = 0;
    scaling_off_x = 0.0;
    scaling_off_y = 0.0;
    modules = {};
    quick_transitions = [];
    groups = [];
  };
in {
  options.programs.obsLazycam = {
    cameraDeviceId = lib.mkOption {
      type = lib.types.str;
      example = "v4l2_input.pci-0000_75_00.0-usb-0_1.1_1.0";
      description = ''
        PipeWire node name of the camera the Active scene should
        capture. Find it via:
            pw-cli ls Node | grep -B1 -A8 'media.class = "Video/Source"'
        The value is stable per camera + USB port + PCI host
        controller — moving the camera to a different USB port will
        change it.

        Required (no default) because the right value is host-
        specific and any plausible default would silently fall back
        to "no camera" on hosts that don't set it explicitly.
      '';
    };

    cameraFormat = lib.mkOption {
      type = lib.types.attrs;
      default = {
        encoded = false;
        video_format = 4; # SPA_VIDEO_FORMAT_YUY2
        width = 1920;
        height = 1080;
      };
      description = ''
        Camera format configuration for the PipeWire stream.
        Encoded as JSON-within-JSON in the OBS scene file. Default
        is MJPG 1920x1080 — the common high-resolution webcam mode
        with hardware JPEG encoding for USB bandwidth efficiency.

        Schema (fields read by camera-portal.c parse_format):
          encoded       — true for compressed formats (MJPG/H264),
                          false for raw (YUY2/NV12/etc)
          video_format  — SPA enum: SPA_MEDIA_SUBTYPE_mjpg=131074
                          (for encoded=true), or SPA_VIDEO_FORMAT_*
                          (for encoded=false)
          width, height — integers, in pixels

        Values:
          SPA_MEDIA_SUBTYPE_mjpg   = 131074  (0x20002)
          SPA_MEDIA_SUBTYPE_h264   = 131073  (0x20001)
          SPA_MEDIA_SUBTYPE_raw    = 1
        See pipewire spa/param/format.h + spa/param/video/raw.h.

        Without a format configured, OBS asks PipeWire for "any
        format" and the negotiation fails with "no more input
        formats" — observed empirically with the C920.
      '';
    };

    cameraFramerate = lib.mkOption {
      type = lib.types.submodule {
        options = {
          numerator = lib.mkOption {
            type = lib.types.int;
            default = 30;
          };
          denominator = lib.mkOption {
            type = lib.types.int;
            default = 1;
          };
        };
      };
      default = {};
      description = ''
        Camera framerate as a numerator/denominator fraction. 30/1
        is the common webcam max. Encoded as JSON-within-JSON
        ({"framerate":{"numerator":30,"denominator":1}}) in the
        OBS scene file.
      '';
    };
  };

  config = {
  # OBS itself + lazycam-relevant plugins. Sourced from the gaming
  # overlay's nixpkgs so face-tracker resolves via pkgs.obs-face-tracker
  # (set up in nix-config's pkgs/ + overlays/).
  home.packages = [
    (pkgs.wrapOBS {
      plugins = [
        pkgs.obs-studio-plugins.obs-backgroundremoval
        pkgs.obs-face-tracker
      ];
    })
  ];

  # Scene collection. Read-only symlink — any edit OBS attempts to
  # persist (e.g. shifting an item, picking a different default scene)
  # will fail at the OS level and be discarded. The right way to
  # change scenes is to edit this module and run `update`.
  xdg.configFile."obs-studio/basic/scenes/lazycam.json".text =
    builtins.toJSON lazycamSceneCollection;

  # user.ini is where OBS 30+ stores the active-profile + active-
  # scene-collection pointers (the legacy global.ini path silently
  # stopped being read for these keys somewhere around OBS 30). Empirical
  # check on this host: OBS ignores [BasicWindow] SceneCollection in
  # global.ini, reads SceneCollection from [Basic] in user.ini.
  #
  # We keep this minimal — anything not declared falls through to
  # OBS's built-in defaults, which is fine. Window geometry / preview
  # snapping / theme prefs are deliberately NOT declared so OBS can
  # use its sensible defaults; the only invariants that matter for
  # the lazycam pipeline are the collection + profile selection and
  # the "don't show the first-run wizard" suppression.
  #
  # Profile=Untitled because we don't ship a declarative profile yet
  # (see module top comment). OBS auto-creates ~/.config/obs-studio/
  # basic/profiles/Untitled/ as a writable dir on first launch.
  xdg.configFile."obs-studio/user.ini".text = ''
    [General]
    FirstRun=false
    ConfirmOnExit=false

    [Basic]
    Profile=Untitled
    ProfileDir=Untitled
    SceneCollection=lazycam
    SceneCollectionFile=lazycam.json
  '';

  # obs-websocket config. Lives in plugin_config/, NOT global.ini's
  # legacy [WebsocketAPI] section. server_port matches what lazycam's
  # --obs-url defaults to (ws://127.0.0.1:4455). auth_required=false
  # is safe because lazycam.requireLoopback() refuses to dial
  # anything off 127.0.0.0/8 / ::1 / localhost — the access boundary
  # is the loopback interface itself, not a shared secret.
  #
  # alerts_enabled=false suppresses OBS's "WebSocket client
  # connected" popup; lazycam connects/reconnects often enough that
  # the popup is noise.
  xdg.configFile."obs-studio/plugin_config/obs-websocket/config.json".text = builtins.toJSON {
    server_enabled = true;
    server_port = 4455;
    auth_required = false;
    server_password = "";
    alerts_enabled = false;
    first_load = false;
  };
  };
}
