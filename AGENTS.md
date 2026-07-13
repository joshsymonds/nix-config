# Repository operating notes

## Gnomon builds and deployment

- Never build Gnomon's Home Manager activation package or NixOS system
  closure on another host, especially Vermissian. Evaluating the target
  closure can trigger large local downloads and CUDA builds.
- For Gnomon changes, commit and push the branch, SSH to
  `joshsymonds@gnomon`, pull the branch there, and run the build or
  `nixos-rebuild` locally on Gnomon.
