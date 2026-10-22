# Point every TLS client at the system CA bundle.
#
# NixOS distrusts roots by writing them into /etc/ssl/certs as TRUSTED
# CERTIFICATE blocks with every use rejected (security/ca.nix; e.g.
# emSign ECC Root CA - G3 after the Oct 2026 eMudhra weak-key compromise,
# CVE-2026-113470). Anything that reads a bundle of its own never sees
# that distrust: the plain pkgs.cacert in the store, or a vendored copy.
# Each variable below sends one such client back to /etc (found by
# sweeping system closures for the emSign root's key):
#   NIX_SSL_CERT_FILE                certifi (nixpkgs patch), nixpkgs openssl
#   SSL_CERT_FILE                    Perl IO::Socket::SSL (else Mozilla::CA),
#                                    rustls-native-certs
#   AWS_CA_BUNDLE                    botocore / awscli vendored cacert.pem
#   GRPC_DEFAULT_SSL_ROOTS_FILE_PATH gRPC's bundled roots.pem
#   UV_SYSTEM_CERTS                  uv's compiled-in webpki-roots
# All of them honour the rejection (checked with a synthetic rejected root).
# Set for login shells and in every NixOS-defined system unit's
# Environment=, so services (home-assistant's certifi, etc.) get them too.
_: let
  bundle = "/etc/ssl/certs/ca-certificates.crt";
  vars = {
    NIX_SSL_CERT_FILE = bundle;
    SSL_CERT_FILE = bundle;
    AWS_CA_BUNDLE = bundle;
    GRPC_DEFAULT_SSL_ROOTS_FILE_PATH = bundle;
    UV_SYSTEM_CERTS = "1";
  };
in {
  environment.variables = vars;
  systemd.globalEnvironment = vars;
}
