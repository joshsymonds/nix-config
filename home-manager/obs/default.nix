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
  lib,
  pkgs,
  ...
}: let
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
      # The real webcam source. v4l2_input — NOT pipewire-camera-source.
      #
      # We attempted the PipeWire-portal source first because it has
      # .show/.hide hooks (releases the camera handle when not displayed,
      # making the hardware LED honestly track scene visibility). But
      # format negotiation through xdg-desktop-portal-camera empirically
      # fails on this stack with "no more input formats" across multiple
      # format configurations (YUY2 raw, MJPG encoded, no constraints).
      # Setting that path aside for now.
      #
      # v4l2_input works reliably but its plugin has no show/hide hooks
      # (plugins/linux-v4l2/v4l2-input.c registers only .create /
      # .destroy / .update). So the source holds the camera fd for its
      # entire lifetime — the LED stays lit while OBS runs, regardless
      # of which scene is the program scene. Lazycam closes that gap
      # at the daemon layer: on Activate it issues a SetInputSettings
      # RPC writing device_id="/dev/video0", which opens the camera; on
      # Deactivate it writes device_id="", which makes v4l2_update fail
      # the reopen and release the prior fd (LED off). See lazycam's
      # SetCameraDevice in switcher.go.
      #
      # We ship the source with device_id="" by default so OBS launches
      # in the LED-off state. The first Activate transition fills it in.
      #
      # pixelformat 1196444237 = the v4l2 fourcc 'MJPG' as little-endian
      # uint32 ('M'|'J'<<8|'P'<<16|'G'<<24). Pins the device to MJPG so
      # 1080p30 fits within USB 2.0 bandwidth (uncompressed YUYV would
      # choke at >480p).
      {
        id = "v4l2_input";
        versioned_id = "v4l2_input";
        uuid = uuid.webcam;
        name = "Real Webcam";
        settings = {
          device_id = "";
          input = -1;
          pixelformat = 1196444237;
          framerate = -1;
          resolution = -1;
          buffering = false;
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
}
