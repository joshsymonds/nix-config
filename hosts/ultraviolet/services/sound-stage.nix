{
  config,
  inputs,
  ...
}: {
  imports = [inputs.sound-stage.nixosModules.default];

  age.secrets."sound-stage-env" = {
    file = ../../../secrets/hosts/ultraviolet/sound-stage-env.age;
    owner = "sound-stage";
    group = "sound-stage";
    mode = "0400";
  };

  services.sound-stage = {
    enable = true;
    # 8080 is taken by sabnzbd's container.
    port = "8088";
    deckURL = "http://172.31.0.39:9000";
    delyricURL = "http://172.31.0.98:9001";
    libraryDir = "/mnt/music/sound-stage";
    # The Deck mounts the same NFS export at /var/mnt — paths sent to its
    # POST /refresh are translated from libraryDir to this prefix.
    deckLibraryDir = "/var/mnt/music/sound-stage";
    environmentFile = config.age.secrets."sound-stage-env".path;
  };

  services.caddy.virtualHosts."sing.home.husbuddies.gay".extraConfig = ''
    reverse_proxy /* localhost:8088
    import cloudflare
  '';
}
