{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.programs.go.enable or false;
in {
  config = lib.mkIf cfg {
    programs.go = {
      package = pkgs.go_1_26;
      env = {
        GOPATH = "${config.home.homeDirectory}/go";
        GOBIN = "${config.home.homeDirectory}/go/bin";
      };
    };

    home = {
      packages =
        (with pkgs; [
          go-tools
          gopls
          delve
          gofumpt
          golines
          gotestsum
          goreleaser
          go-task
          ko
        ])
        ++ [
          pkgs.golangciLintBin
          pkgs.deadcode
        ];

      sessionVariables = {
        GO111MODULE = lib.mkDefault "on";
        GOPROXY = lib.mkDefault "https://proxy.golang.org,direct";
        GOTELEMETRY = lib.mkDefault "off";
        GOSUMDB = lib.mkDefault "sum.golang.org";
      };

      sessionPath = lib.mkAfter ["$HOME/go/bin"];

      file.".go-templates/.keep".text = "";

      shellAliases = {
        got = "go test ./...";
        gotv = "go test -v ./...";
        gotr = "go test -race ./...";
        gotc = "go test -cover ./...";
        gol = "golangci-lint run";
        golf = "golangci-lint run --fix";
        golu = "echo 'golangci-lint is managed by Nix (pkgs.golangciLintBin); bump pkgs/golangci-lint-bin to update.'";
        gomu = "go mod download && go mod tidy";
        gomv = "go mod vendor";
        gob = "go build";
        gor = "go run";
        gofmtall = "gofumpt -l -w .";
      };
    };

    programs.git.settings."diff.go" = {
      xfuncname = "^[ \t]*(func|type)[ \t]+([a-zA-Z_][a-zA-Z0-9_]*)";
    };
  };
}
