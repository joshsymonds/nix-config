{
  lib,
  stdenvNoCC,
  fetchzip,
}:
stdenvNoCC.mkDerivation rec {
  pname = "aerospace";
  version = "0.21.3-Beta";

  src = fetchzip {
    url = "https://github.com/nikitabobko/AeroSpace/releases/download/v${version}/AeroSpace-v${version}.zip";
    hash = "sha256-JHXtF3IKUbge7z2cMBi4L9IruiByNPCIKugLe4ymvys=";
    stripRoot = true;
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/Applications
    cp -R AeroSpace.app $out/Applications/

    install -Dm755 bin/aerospace $out/bin/aerospace

    install -Dm644 manpage/*.1 -t $out/share/man/man1
    install -Dm644 shell-completion/bash/aerospace \
      $out/share/bash-completion/completions/aerospace
    install -Dm644 shell-completion/zsh/_aerospace \
      $out/share/zsh/site-functions/_aerospace
    install -Dm644 shell-completion/fish/aerospace.fish \
      $out/share/fish/vendor_completions.d/aerospace.fish

    mkdir -p $out/share/doc/${pname}
    cp -R legal $out/share/doc/${pname}/

    runHook postInstall
  '';

  meta = with lib; {
    description = "i3-inspired tiling window manager for macOS";
    homepage = "https://github.com/nikitabobko/AeroSpace";
    license = licenses.mit;
    platforms = ["aarch64-darwin" "x86_64-darwin"];
    mainProgram = "aerospace";
  };
}
