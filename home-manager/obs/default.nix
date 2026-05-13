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
    faceTrackerFilter = "77777777-7777-7777-7777-777777777777";
  };

  # Absolute store path to the dlib 5-point landmark predictor that
  # `face_tracker_filter` loads when landmark_detection is enabled.
  # pkgs/obs-face-tracker/default.nix installs the file at
  # `<modelDir>/dlib_face_landmark_model/shape_predictor_5_face_landmarks.dat`
  # (modelDir exposed via passthru). Could rely on the plugin's own
  # obs_module_file() auto-discovery (which would also find this file
  # since wrapOBS symlinks the plugin's share/ into the unified tree),
  # but the explicit path is more debuggable from logs and OBS Properties.
  faceLandmarkData =
    "${pkgs.obs-face-tracker}/${pkgs.obs-face-tracker.passthru.modelDir}/dlib_face_landmark_model/shape_predictor_5_face_landmarks.dat";

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
          # Face tracker filter — norihiro/obs-face-tracker. The "Center
          # Stage" analog: detects the face with dlib, smooths a crop
          # rect with a PI controller + low-pass filter, applies a GPU
          # resample so the face stays roughly centered + auto-zoomed
          # regardless of where the user is in frame.
          #
          # Filter ordering invariant: face_tracker_filter runs FIRST,
          # background_removal runs SECOND. The face tracker produces a
          # cropped/zoomed RGB frame; bg-removal then operates on that
          # already-framed image. Reversing the order would have RVM
          # segment the wide frame and then the tracker would crop the
          # already-alphaed result — same matte quality but the
          # tracker's detector runs on more pixels for no benefit.
          {
            id = "face_tracker_filter";
            versioned_id = "face_tracker_filter";
            uuid = uuid.faceTrackerFilter;
            name = "Face Tracker";
            settings = {
              # detector_engine: 0 = dlib HOG, 1 = dlib CNN.
              # HOG runs single-threaded on CPU and is what every other
              # consumer-grade face tracker uses; ~3 ms/frame on a
              # 9800X3D. CNN gives better small-face recall but ~50x
              # the cost. V1 picks HOG — single face, full-frame, no
              # need for the CNN's recall.
              detector_engine = 0;
              # detector_dlib_hog_model / detector_dlib_cnn_model
              # are intentionally not set here. The plugin's update()
              # path runs obs_module_file() against
              # `dlib_hog_model/frontal_face_detector.dat` and sets
              # those defaults from the resolved path
              # (face-tracker-manager.cpp:459/466). Since wrapOBS
              # symlinks our pkgs.obs-face-tracker share/ tree into
              # the unified plugin data dir, obs_module_file() finds
              # both .dat files automatically.

              # landmark_detection: when enabled the filter runs dlib's
              # 5-point shape predictor on each detected face and uses
              # the landmarks (eye corners, nose tip) instead of the raw
              # bbox center for the tracking target. Smoother and more
              # stable than bbox-only tracking — bbox jitters by several
              # px per frame as the HOG response surface shifts; landmarks
              # are sub-pixel-stable.
              landmark_detection = true;
              landmark_detection_data = faceLandmarkData;

              # Tracking dynamics + crop padding + image scale are
              # left at the plugin's defaults (face-tracker.cpp:317-329
              # and face-tracker-manager.cpp:451-457). These are the
              # values upstream tuned over multiple releases — Kp=0.95
              # / Ki=0.3 PI gains with Td=0.42 derivative + Tdlpf=2.0
              # low-pass produces the characteristic "subject-following
              # cinematographer" feel without lurching or overshoot.
              # Re-tune here only when an empirical use case demands it.
            };
            enabled = true;
          }
          # Background Removal filter — locaal-ai's obs-backgroundremoval
          # plugin (was royshil/, rename 2024). Runs in BLUR-OUTPUT mode:
          # the filter composites a portrait-mode frame inline — sharp
          # subject + Kawase-blurred background — rather than emitting
          # alpha for a downstream bg-layer source.
          #
          # The model_select value MUST be the literal MODEL_RVM
          # constant from upstream src/consts.h — the plugin maps
          # this string to the actual ONNX file in
          # data/models/. Display labels like "Robust Video Matting"
          # would not work as the stored value.
          # Source: https://github.com/locaal-ai/obs-backgroundremoval/blob/main/src/consts.h
          #
          # Model choice (RVM): the only model in v1.3.7 with recurrent
          # temporal state (r1i-r4i tensors carry mask history across
          # frames) — gives the least silhouette flicker on a video
          # call. RMBG-1.4 has sharper per-frame edges but is stateless
          # and additionally crashes on CUDA EP in this plugin version
          # (see locaal-ai/obs-backgroundremoval#760 — maintainer
          # explicitly disabled GPU inference for RMBG due to ORT × qint8
          # incompatibility). Stay on RVM.
          #
          # Blur strategy: the filter's built-in Kawase pass (blur_background)
          # combined with focal-blur (enable_focal_blur) gives a depth-of-
          # field bokeh that varies by distance from focus plane. Two knobs
          # to tune look: pass count (heaviness of blur) and focus depth
          # (how aggressively blur ramps off). The matte-reconstruction
          # pipeline below (threshold=1.0 seed + smooth+expand+feather)
          # is tuned to keep hair edges generous so the blur doesn't
          # halo around the silhouette.
          #
          # If blur quality ever caps out: switch to alpha-output mode
          # (blur_background = 0) and put a separately-blurred copy of
          # Real Webcam behind in the scene graph. That lets you use
          # arbitrary blur filters (gaussian, box, custom shader) instead
          # of just Kawase, and removes the blur-pass-count ceiling.
          #
          # All other settings (mask_every_x_frames, stop_when_source_is_inactive,
          # etc.) are left at the plugin's documented defaults
          # (background_filter_defaults in src/background-filter.cpp).
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
              # 5070 Ti.
              useGPU = "cuda";
              # advanced = true unlocks the focal-blur settings group
              # in the OBS filter properties UI. Without this flag the
              # enable_focal_blur / blur_focus_point / blur_focus_depth
              # values below would still take effect (they're filter
              # settings, not UI gating), but the UI would not expose
              # them — making it impossible to re-tune from the OBS
              # window. Keep this on so the dialog stays useful.
              advanced = true;
              # blur_background: number of Kawase blur passes (0-20).
              # Higher = heavier blur. Each pass roughly doubles the
              # effective blur radius for ~constant per-pass GPU cost,
              # so doubling pass count gives much more than 2x blur
              # without ~2x cost. At 16 the room behind the user reads
              # as a soft, defocused gradient — distinct shapes still
              # legible but no identifiable detail. Below ~10 the blur
              # is too subtle to hide a busy background; above ~18 the
              # halo around hair edges starts to bleed onto the subject
              # because the Kawase kernel reaches past the matte
              # boundary. Tune in 2-step increments via the OBS UI;
              # commit a final value here once the look is dialed in.
              blur_background = 16;
              # enable_focal_blur + blur_focus_point/depth: switches
              # the blur shader from uniform Kawase to a focal-blur
              # variant that varies blur magnitude by distance from
              # the focal plane. blur_focus_point = 0.0 anchors the
              # focus at the back of the depth range, blur_focus_depth
              # = 0.12 keeps a narrow in-focus band — together this
              # yields the "subject sharp, room falls off gradually"
              # depth-of-field look that uniform blur can't match.
              enable_focal_blur = true;
              blur_focus_point = 0.0;
              blur_focus_depth = 0.12;
              # threshold + post-processing strategy: counterintuitive
              # but empirically the best matte on this rig.
              #
              # threshold = 1.0 binarizes RVM's pha at the maximum
              # cutoff — only pixels with alpha == 1.0 (the model's
              # high-confidence core of the silhouette) survive as
              # foreground. Everything else becomes background. This
              # would produce a tiny matte on its own — but the
              # post-processing pipeline below treats the core as a
              # SEED and reconstructs a generous silhouette around it.
              enable_threshold = true;
              threshold = 1.0;
              # contour_filter = 0.28 drops any foreground island
              # smaller than 28% of frame area; with threshold=1.0
              # this removes the speckle of high-confidence pixels
              # outside the main body, leaving exactly one large
              # contour (the user's core).
              contour_filter = 0.28;
              # smooth_contour = 1.0 maximally smooths the binary
              # silhouette before resizing back, eliminating the
              # jaggy artifacts the threshold=1.0 binarize would
              # otherwise produce.
              smooth_contour = 1.0;
              # mask_expansion = 22 erodes the background mask (i.e.
              # grows the foreground silhouette outward) by 22
              # iterations — rebuilding a generous halo around the
              # confident core. This is what makes the matte cover
              # the full body including hair edges and shoulders
              # despite threshold being maxed out.
              mask_expansion = 22;
              # feather = 1.0 (max) gives the widest possible soft
              # falloff at the silhouette edge — the body transitions
              # to background over a wide gradient rather than a hard
              # boundary.
              feather = 1.0;
              # temporal_smooth_factor controls per-frame EMA over
              # the mask. Semantics: factor is the weight on the NEW
              # frame in addWeighted(new, factor, old, 1-factor),
              # so HIGHER = more reactive (less smoothing), LOWER =
              # more smoothed (laggier). 0.0 (and 1.0) bypasses
              # the EMA branch entirely — every frame's mask is the
              # raw inference output. RVM's internal recurrent state
              # (r1i-r4i) still provides inter-frame coherence, so
              # bypassing the OpenCV EMA does not produce flicker.
              temporal_smooth_factor = 0.0;
              # enable_image_similarity: if true the plugin skips
              # inference when consecutive frames are "similar
              # enough" (PSNR-based). Saves GPU but freezes the
              # matte on subtle movement. On a 5070 Ti every-frame
              # inference is cheap; keep off for reactivity.
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
