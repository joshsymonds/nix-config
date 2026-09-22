{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule (finalAttrs: {
  pname = "cliproxyapi";
  version = "7.3.13";

  src = fetchFromGitHub {
    owner = "router-for-me";
    repo = "CLIProxyAPI";
    tag = "v${finalAttrs.version}";
    hash = "sha256-9ZiYPBEoxTcZaomY0Be4Q5hwQf5FCfdbvcJzYEGI+So=";
  };

  # Built from source rather than the upstream release binary so this patch
  # can ride along. The Codex backend accepts service_tier=priority (Fast
  # mode) on HTTP POST /responses but serves it at the standard tier; only the
  # Responses websocket transport honors it, and upstream uses that transport
  # only when the downstream is a websocket too (router-for-me/CLIProxyAPI
  # #4586, closed as not planned). The patch routes a priority request —
  # patchbay's Claude-format `speed: fast`, which the Claude→Codex translator
  # already maps to priority, included — over the websocket executor from any
  # downstream, when the auth enables websockets. Carries its own tests.
  patches = [./priority-over-websocket.patch];

  vendorHash = "sha256-r3yWkdMcM40G9jV7MxW/qNv3E9WrHavFilW24quEf+8=";

  subPackages = ["cmd/server"];

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=${finalAttrs.version}"
  ];

  # The package the patch touches is tested where the patch is developed;
  # upstream's full suite wants network and minutes this build should not.
  doCheck = false;

  postInstall = ''
    mv "$out/bin/server" "$out/bin/cli-proxy-api"
    install -Dm644 config.example.yaml "$out/share/doc/cliproxyapi/config.example.yaml"
  '';

  meta = {
    description = "Proxy that exposes CLI-agent subscriptions (ChatGPT Codex, Gemini, Claude) as OpenAI/Anthropic-compatible API endpoints";
    homepage = "https://github.com/router-for-me/CLIProxyAPI";
    changelog = "https://github.com/router-for-me/CLIProxyAPI/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "cli-proxy-api";
  };
})
