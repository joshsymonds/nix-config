# gnomon-only: subscribe to the Claude ntfy topic and surface every
# message as a DankMaterialShell desktop popup + a synthesized chime.
#
# This is the gnomon end of the "ntfy is the one true notification path"
# design. Claude's own terminal notification is disabled everywhere
# (settings.json preferredNotifChannel=notifications_disabled); the
# Stop/Notification hooks (home-manager/claude-code/hooks/ntfy-notifier.sh)
# POST to the ntfy topic with a classifying tag. Every agent — gnomon's
# own AND vermissian's — therefore comes back through this one
# subscriber, so the desktop popup and the watch push are the same
# signal from the same source. gnomon's own agents loop back through
# the ntfy server by design (chosen over a fast local path so there is
# exactly one code path and the two hosts behave identically).
#
# Reuses the `ntfy-url` agenix secret declared by the claude-code HM
# module (imported on gnomon alongside this one); the URL is read from
# that path at service start, never baked into the store.
{
  config,
  pkgs,
  ...
}: let
  sounds = pkgs.claude-notify-sounds;

  # ntfy runs this per message with $event/$title/$message/$tags/... in
  # the environment. The hook sets the `question` tag when Claude is
  # parked waiting on the user (priority 5) and `white_check_mark` when
  # it just finished (priority 3) — branch the chime + libnotify urgency
  # on that. notify-send reaches DMS over the session bus the user
  # service already has (same path morgen-notifier uses).
  handler = pkgs.writeShellScript "ntfy-notify-handler" ''
    set -u
    [ "''${event:-message}" = message ] || exit 0
    case ",''${tags:-}," in
      *,question,*) sound=needs-you; urgency=critical ;;
      *)            sound=done;      urgency=normal   ;;
    esac
    echo "ntfy-notify: $sound urgency=$urgency tags=''${tags:-} title=''${title:-}" >&2
    # suppress-sound: we play our own classified chime below, so tell DMS
    # not to also play its generic notification sound. DMS honors this
    # freedesktop hint as of the josh/notif-suppress-sound patch on the
    # dank-material-shell integration branch — without that patch DMS
    # double-sounds nondeterministically (dedup-dependent).
    ${pkgs.libnotify}/bin/notify-send -a Claude -u "$urgency" \
      -h boolean:suppress-sound:true -- \
      "''${title:-Claude}" "''${message:-}"
    exec ${pkgs.pipewire}/bin/pw-play "${sounds}/$sound.wav"
  '';

  # Literal agenix-hm path; the string contains "''${XDG_RUNTIME_DIR}"
  # verbatim (home-manager agenix doesn't pre-resolve it). systemd
  # Environment= won't expand that, but bash will — XDG_RUNTIME_DIR is
  # always in the user-service environment — so read it in-shell.
  secretPath = config.age.secrets."ntfy-url".path;

  subscriber = pkgs.writeShellApplication {
    name = "ntfy-notify";
    runtimeInputs = [pkgs.ntfy-sh pkgs.coreutils];
    text = ''
      # shellcheck disable=SC2154  # XDG_RUNTIME_DIR comes from systemd --user
      secret="${secretPath}"
      url="$(cat "$secret")"
      [ -n "$url" ] || { echo "ntfy-notify: empty secret at $secret" >&2; exit 1; }
      exec ntfy subscribe "$url" ${handler}
    '';
  };
in {
  systemd.user.services.ntfy-notify = {
    Unit = {
      Description = "Surface Claude ntfy notifications as desktop popups + chime";
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = "${subscriber}/bin/ntfy-notify";
      # ntfy subscribe reconnects on its own; Restart only catches a hard
      # exit (e.g. the agenix path not decrypted yet at early session).
      Restart = "always";
      RestartSec = 5;
    };
    Install.WantedBy = ["graphical-session.target"];
  };
}
