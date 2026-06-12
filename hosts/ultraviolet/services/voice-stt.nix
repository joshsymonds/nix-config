# Voice v1: standalone Wyoming STT engine (sink-neutral by design — HA's
# Assist pipeline is one client; future non-HA sinks speak the same Wyoming
# TCP protocol directly). parakeet-tdt-0.6b-v2 int8 on CPU: more accurate
# than whisper large-v3 (6.05% vs 7.44% WER) at ~0.3-0.6s per utterance.
{
  pkgs,
  lib,
  ...
}: {
  users.users.voice-stt = {
    isSystemUser = true;
    group = "voice-stt";
  };
  users.groups.voice-stt = {};

  systemd.services.voice-stt = {
    description = "Wyoming STT (parakeet-tdt-0.6b-v2 int8, CPU)";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];

    environment = {
      # huggingface_hub cache — model (~600MB) downloads once, persists in
      # the state directory across restarts and rebuilds.
      HF_HOME = "/var/lib/voice-stt/hf";
      # int8 weights: same accuracy as fp32 in benchmarks, much faster on CPU
      # (threaded through to onnx_asr.load_model by our package patch).
      ONNX_ASR_QUANTIZATION = "int8";
    };

    serviceConfig = {
      Type = "simple";
      User = "voice-stt";
      Group = "voice-stt";
      Restart = "always";
      RestartSec = "5s";

      # Loopback only: HA runs on this host; nothing else needs it yet.
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkgs.wyoming-onnx-asr)
        "--model parakeet-v2"
        "--cpu"
        "--threads 4"
        "--uri tcp://127.0.0.1:10300"
      ];

      StateDirectory = "voice-stt";
      WorkingDirectory = "/var/lib/voice-stt";

      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };
}
