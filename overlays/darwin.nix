final: prev:
if (prev ? stdenv) && prev.stdenv.hostPlatform.isDarwin
then {
  aerospace = final.callPackage ../pkgs/aerospace {};
}
else {}
