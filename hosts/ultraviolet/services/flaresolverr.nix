_: {
  virtualisation.oci-containers.containers.flaresolverr = {
    image = "flaresolverr/flaresolverr:v3.3.18";
    # Loopback-only publish instead of --network=host: Prowlarr (native
    # service, same host) reaches this over localhost either way, and this
    # keeps flaresolverr off the LAN/podman bridge entirely.
    ports = ["127.0.0.1:8191:8191"];
    extraOptions = [
      "--security-opt=no-new-privileges"
      "--memory=2g"
    ];
  };
}
