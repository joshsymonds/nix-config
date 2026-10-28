{
  awscli2,
  bash,
  coldsnap,
  coreutils,
  curl,
  jq,
  lib,
  nix,
  openssh,
  runCommand,
  writeShellApplication,
}: let
  launcher = writeShellApplication {
    name = "ec2";
    runtimeInputs = [awscli2 coldsnap jq curl openssh nix coreutils];
    text = builtins.readFile ./ec2.sh;
    passthru = {inherit tests;};
  };

  # The same script with only the real coreutils and jq on its path. The test
  # puts stub aws/nix/coldsnap/curl/ssh ahead of $PATH, so the launcher reaches
  # them there (writeShellApplication prepends runtimeInputs, so stubs must not
  # be runtimeInputs).
  stubbed = writeShellApplication {
    name = "ec2";
    runtimeInputs = [coreutils jq];
    text = builtins.readFile ./ec2.sh;
  };

  tests.stubbed = runCommand "ec2-stubbed-test" {} ''
    ${lib.getExe bash} ${./test.sh} ${lib.getExe stubbed}
    touch $out
  '';
in
  launcher
