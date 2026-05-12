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
    activeBackground = "55555555-5555-5555-5555-555555555555";
    bgRemovalFilter = "66666666-6666-6666-6666-666666666666";
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
          # framerate is the v4l2 timeperframe fraction (seconds per
          # frame, INVERSE of fps) packed as
          # `(numerator << 16) | denominator` per OBS's
          # plugins/linux-v4l2/v4l2-helpers.h: v4l2_pack_tuple.
          # For 30fps: timeperframe 1/30 → (1 << 16) | 30 = 65566.
          #
          # Previously had this wrong as (30 << 16) | 1 = 1966081,
          # which the plugin decoded as 30 seconds per frame ≈
          # 0.033fps. The C920 clamped that up to its 5fps minimum,
          # producing visibly choppy capture even though OBS's
          # internal canvas renderer ran at 30fps (it just kept
          # re-emitting the same stale frame between camera reads).
          framerate = 65566;
          resolution = -1;
          buffering = false;
        };
        sync = 0;
        muted = false;
        private_settings = {};
        filters = [
          # Background Removal filter — royshil/locaal-ai's
          # obs-backgroundremoval plugin. Configured per V1 plan:
          # alpha-output mode + RVM model + CPU inference +
          # feathered edges.
          #
          # The model_select value MUST be the literal MODEL_RVM
          # constant from upstream src/consts.h — the plugin maps
          # this string to the actual ONNX file in
          # data/models/. Display labels like "Robust Video Matting"
          # would not work as the stored value.
          # Source: https://github.com/locaal-ai/obs-backgroundremoval/blob/main/src/consts.h
          #
          # blur_background = 0 is the architectural pin: 0 means
          # alpha-output (let the bg-layer source show through);
          # >0 would in-place-blur the source and never expose
          # alpha. V2's image/video/shader bg-swap requires alpha
          # output — see the epic's "blur-output mode for V1
          # REJECTED" approach.
          #
          # feather = 0.05 — deviates from the plugin default
          # (0.0) to soften the alpha edges. Matches the "feathered
          # and beautiful" V1 quality bar; user can dial up/down
          # later if hair edges look too soft or too hard.
          #
          # All other settings deferred to the plugin's documented
          # defaults (background_filter_defaults in
          # src/background-filter.cpp): threshold=0.5,
          # temporal_smooth_factor=0.85, mask_every_x_frames=1,
          # stop_when_source_is_inactive=true (important — pauses
          # the filter when Standby is the program scene so we
          # don't burn CPU on hidden source).
          {
            id = "background_removal";
            versioned_id = "background_removal";
            uuid = uuid.bgRemovalFilter;
            name = "Background Removal";
            settings = {
              # Matches the obs-backgroundremoval MODEL_RVM constant
              # which our ml overlay rewrites to "...fp32.onnx" (see
              # overlays/default.nix). The .onnx variant dodges a
              # CUDA EP SEGV in the bundled .ort flatbuffer's frozen
              # graph optimization — full RFC in the overlay comment.
              model_select = "models/rvm_mobilenetv3_fp32.onnx";
              # CUDA EP. The ml overlay rebuilds `onnxruntime` with
              # CUDA support (overlays/default.nix); the plugin links
              # against it via `-DUSE_SYSTEM_ONNXRUNTIME=ON` and the
              # runtime EP selection here switches inference to the
              # 5070 Ti. CPU mode bottlenecked at ~40% process CPU
              # with poor framerate during real-world Active sessions
              # — empirically met the V1 epic's "DO NOT REVISIT
              # UNLESS CPU inference drops frames" clause.
              useGPU = "cuda";
              # blur_background: in-place Kawase blur strength (0-20).
              # Setting > 0 disables alpha-output mode and instead
              # produces a single composited frame with the user
              # sharp + the room blurred. This is the "portrait
              # mode" look most video-call apps deliver natively.
              #
              # NOTE: this deviates from the V1 epic's chosen
              # alpha+layer architecture (epic anti-pattern: "NO
              # blur_background > 0 in V1"). Done for visualization
              # — flat-gray bg-layer made it hard to evaluate matte
              # quality. To return to alpha+layer for V2's
              # image/video/shader bg swap, flip this back to 0;
              # the Active Background color_source_v3 is still in
              # the scene and will become visible again.
              blur_background = 15;
              # threshold: the plugin binarizes RVM's soft alpha at
              # this cutoff. RVM gives confident foreground pixels
              # an alpha of ~1.0 and ramps DOWN toward the silhouette
              # boundary; anything below the cutoff becomes
              # background. 0.1 is intentionally permissive — we'd
              # rather scoop in a bit of room behind the user's
              # shoulders than ever cut INTO the body.
              threshold = 0.1;
              # mask_expansion: grow the foreground mask outward by
              # N pixels (range -30 to +30). +10 is the sweet spot —
              # +15 was too generous (visible rim of room around
              # shoulders), +5 occasionally cut into body.
              mask_expansion = 10;
              # feather: gaussian blur radius on the mask edge.
              # 0.25 produces a noticeably softer rim than 0.15;
              # the body-edge transition fades over a wider zone,
              # which masks the discrete "snap to mask boundary"
              # the human eye catches with sharp cutouts.
              feather = 0.25;
              # smooth_contour: how aggressively to smooth the
              # mask's boundary polyline. Default 0.5; raising to
              # 0.7 makes the silhouette ride along longer curves
              # instead of tracking fine concavities, again helping
              # the cut-out feel less surgical / more natural.
              smooth_contour = 0.7;
              # temporal_smooth_factor: per-frame EMA blend with
              # previous mask. Default 0.85 = 15% new + 85% old →
              # very stable but laggy on movement. RVM is already
              # recurrent (has r1i/r2i/r3i/r4i state inputs), so
              # the model itself smooths across time; this setting
              # is *additional* smoothing on top. Dropping to 0.3
              # makes the matte snappier — the model's internal
              # recurrence still provides flicker resistance.
              temporal_smooth_factor = 0.3;
              # enable_image_similarity: if true, the plugin
              # compares consecutive frames and skips inference
              # when they're "similar enough" (PSNR-based,
              # threshold default 35.0). Saves GPU but freezes
              # the matte during subtle movements like head tilts.
              # On a 5070 Ti, every-frame inference is cheap;
              # disable the skip for maximum reactivity.
              enable_image_similarity = false;
            };
            enabled = true;
          }
        ];
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

      # Active Background: the layer that sits BEHIND the webcam in
      # the Active scene. V1 ships a neutral medium-dark gray solid
      # color (0xFF404040 — gray at ~25% lightness, kind to colour
      # grading and undistracting for video calls). V2 will swap
      # this single source for an image / video / shader source
      # without touching the rest of the pipeline — only the
      # `color_source_v3` entry here changes, the scene composition
      # stays identical.
      #
      # Currently invisible because the webcam's bounds-based
      # transform fills the canvas; this layer becomes visible once
      # background_removal runs in alpha-output mode and cuts the
      # user out of the foreground.
      {
        id = "color_source_v3";
        versioned_id = "color_source_v3";
        uuid = uuid.activeBackground;
        name = "Active Background";
        settings = {
          color = 4282400832;
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
          # Two scene items, back-to-front render order:
          # array[0] = Active Background (rendered FIRST, behind)
          # array[1] = Real Webcam      (rendered SECOND, in front)
          #
          # The webcam covers the whole canvas via its bounds-based
          # transform, so the bg is invisible today — it becomes
          # visible once background_removal runs in alpha-output
          # mode and cuts the user out, letting the bg show through.
          id_counter = 3;
          custom_size = false;
          items = [
            # Back-layer: Active Background color source.
            # Default top-left transform is fine — the source is
            # already 1920x1080 (canvas-sized), so no scaling needed.
            (defaultItemTransform
              // {
                name = "Active Background";
                source_uuid = uuid.activeBackground;
                id = 2;
              })

            # Front-layer: Real Webcam with bounds-based scaling so
            # it fills the canvas centered regardless of the
            # camera's native resolution. The C920 reports 1920x1080
            # in MJPG mode and 1280x720 in YUYV mode — raw scale.x/y
            # values would give different on-canvas sizes per mode.
            # bounds_type=3 (OBS_BOUNDS_SCALE_OUTER) scales the
            # source to cover the bounds rectangle while preserving
            # aspect; slight crop on the long axis is fine for 16:9
            # webcam on 16:9 canvas (no crop when modes match).
            # SCALE_INNER (=2) would leave letterbox bars on the
            # short axis — wrong for a face-fill framing.
            #
            # align=0 means CENTER (OBS's align is a bitmask:
            # LEFT=1, RIGHT=2, TOP=4, BOTTOM=8; 0 = no flags = center
            # in both axes). pos=(960,540) is canvas center, where
            # the alignment anchor lands.
            #
            # scale_filter="bicubic" — smoother resize than the
            # default "disable" (point sampling).
            (defaultItemTransform
              // {
                name = "Real Webcam";
                source_uuid = uuid.webcam;
                id = 1;
                align = 0;
                bounds_type = 3;
                bounds = {
                  x = 1920.0;
                  y = 1080.0;
                };
                pos = {
                  x = 960.0;
                  y = 540.0;
                };
                scale_filter = "bicubic";
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

    # Top-level collection fields OBS expects. We deliberately omit
    # `format_version` — OBS emits `"format_version": 2` in its own
    # saves but accepts files without it (the field is informational,
    # not load-bearing for parse). Anything we don't declare here
    # falls through to OBS's built-in defaults.
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
  # OBS itself + lazycam-relevant plugins. Sourced from the gaming
  # overlay's nixpkgs so face-tracker resolves via pkgs.obs-face-tracker
  # (set up in nix-config's pkgs/ + overlays/). Bound to a local
  # variable so both home.packages and the systemd unit ExecStart can
  # reference the same derivation.
  wrappedObs = pkgs.wrapOBS {
    plugins = [
      pkgs.obs-studio-plugins.obs-backgroundremoval
      pkgs.obs-face-tracker
    ];
  };
in {
  home.packages = [wrappedObs];

  # `force = true` on every OBS-managed file. OBS saves config via
  # atomic rename-on-replace (write-temp-then-rename), which silently
  # clobbers the nix-store symlink with a regular writable file. On
  # the next `update`, home-manager would normally see the path is no
  # longer the symlink it expects and rename the offender to
  # `<path>.backup` — but if `.backup` already exists from a prior
  # round, activation fails ("would clobber backup"). force=true tells
  # home-manager to unconditionally overwrite without backing up,
  # which matches this module's invariant: OBS owns nothing here, the
  # config is reset to the declared state on every `update`. Any
  # runtime state OBS would have written (window geometry, recent
  # files, etc.) is intentionally not preserved.

  # Scene collection. Read-only symlink — any edit OBS attempts to
  # persist (e.g. shifting an item, picking a different default scene)
  # will fail at the OS level and be discarded. The right way to
  # change scenes is to edit this module and run `update`.
  xdg.configFile."obs-studio/basic/scenes/lazycam.json" = {
    text = builtins.toJSON lazycamSceneCollection;
    force = true;
  };

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
  xdg.configFile."obs-studio/user.ini" = {
    text = ''
      [General]
      FirstRun=false
      ConfirmOnExit=false

      [Basic]
      Profile=Untitled
      ProfileDir=Untitled
      SceneCollection=lazycam
      SceneCollectionFile=lazycam.json
    '';
    force = true;
  };

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
  xdg.configFile."obs-studio/plugin_config/obs-websocket/config.json" = {
    text = builtins.toJSON {
      server_enabled = true;
      server_port = 4455;
      auth_required = false;
      server_password = "";
      alerts_enabled = false;
      first_load = false;
    };
    force = true;
  };

  # Auto-launch OBS at graphical-session.target with the virtual
  # camera output already running and the main window minimized to
  # the system tray. The point is to make "OBS Cam" permanently
  # available in Zoom / Meet / etc.'s device dropdowns without
  # requiring the user to launch OBS by hand before every call.
  #
  # Privacy invariant is preserved because lazycam recognizes OBS's
  # producer-side open of /dev/video10 as background noise (filtered
  # by comm via services.lazycam.excludeComms). The camera LED only
  # lights when *another* process — Zoom, Meet, ffmpeg — also
  # attaches to /dev/video10.
  #
  # Flags:
  #   --startvirtualcam              auto-start the v4l2 output module
  #   --minimize-to-tray             stay out of the user's way
  #   --disable-missing-files-check  suppress the startup nag dialog
  #                                  (irrelevant for our declarative
  #                                  scene collection)
  systemd.user.services.obs = {
    Unit = {
      Description = "OBS Studio (auto-start with virtual camera)";
      Documentation = ["https://obsproject.com/"];
      PartOf = ["graphical-session.target"];
      After = ["graphical-session.target"];
      # OBS occasionally needs a moment after the compositor is up
      # before its EGL/Vulkan context can attach. Don't let an
      # ExecStart that fails fast spin the restart counter. These
      # directives belong to the [Unit] section per systemd.unit(5)
      # — placing them under [Service] makes systemd silently ignore
      # them and fall back to DefaultStartLimitIntervalSec=10s /
      # DefaultStartLimitBurst=5 (ban after ~5 fast restarts).
      StartLimitIntervalSec = 60;
      StartLimitBurst = 3;
    };
    Service = {
      ExecStart =
        "${lib.getExe wrappedObs}"
        + " --startvirtualcam"
        + " --minimize-to-tray"
        + " --disable-missing-files-check";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };
}
