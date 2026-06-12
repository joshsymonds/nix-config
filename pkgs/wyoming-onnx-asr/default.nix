{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  makeWrapper,
  python3,
}:
# Wyoming protocol server for onnx-asr speech-to-text (parakeet models).
# Upstream is a single-file Python server with bare requirements files, so
# this wraps it over a python3.withPackages environment from nixpkgs rather
# than buildPythonApplication. Upstream pins wyoming==1.8.0 and
# onnxruntime>=1.25.1; nixpkgs ships 1.9.0/1.24.4 — the APIs used
# (wyoming.server/asr/audio/info, ort.SessionOptions) are stable across
# those versions, verified live at deploy.
let
  python = python3.withPackages (ps:
    [
      ps.wyoming
      ps.numpy
      ps.onnx-asr
      ps.onnxruntime
    ]
    # the [hub] extra: huggingface_hub, used to download models on first start
    ++ ps.onnx-asr.optional-dependencies.hub);
in
  stdenvNoCC.mkDerivation {
    pname = "wyoming-onnx-asr";
    version = "1.0.0";

    src = fetchFromGitHub {
      owner = "chiabre";
      repo = "wyoming-onnx-asr";
      tag = "1.0.0";
      hash = "sha256-ZuyyUj42AoZpObPlCBxM92miguja0jiXUipS7BLawSk=";
    };

    nativeBuildInputs = [makeWrapper];

    # Two upstream fixes:
    # 1. Upstream never passes quantization= to onnx_asr.load_model, so it
    #    always loads fp32 weights. Thread it through an env var; unset means
    #    None (fp32), ONNX_ASR_QUANTIZATION=int8 loads the int8 ONNX files.
    # 2. recognize() on a with_vad() model returns Iterator[SegmentResult]
    #    in onnx-asr >=0.11; upstream's hasattr fallback stringifies the
    #    generator and Wyoming clients receive "<generator object ...>" as
    #    the transcript. Join the segment texts instead.
    postPatch = ''
      substituteInPlace wyoming_onnx_asr.py \
        --replace-fail "sess_options=sess_options" \
                       "sess_options=sess_options, quantization=os.environ.get(\"ONNX_ASR_QUANTIZATION\")" \
        --replace-fail 'text = results.text if hasattr(results, "text") else str(results).strip()' \
                       'text = results.text if hasattr(results, "text") else (results.strip() if isinstance(results, str) else " ".join(seg.text for seg in results).strip())'
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 wyoming_onnx_asr.py $out/share/wyoming-onnx-asr/wyoming_onnx_asr.py
      makeWrapper ${python}/bin/python3 $out/bin/wyoming-onnx-asr \
        --add-flags $out/share/wyoming-onnx-asr/wyoming_onnx_asr.py
      runHook postInstall
    '';

    meta = {
      description = "Wyoming protocol server for onnx-asr (parakeet) speech-to-text";
      homepage = "https://github.com/chiabre/wyoming-onnx-asr";
      license = lib.licenses.mit;
      mainProgram = "wyoming-onnx-asr";
      platforms = lib.platforms.linux;
    };
  }
