{
  pkgs,
  vermissian ? (builtins.getFlake (toString ../.)).nixosConfigurations.vermissian.config,
}: let
  privateStoreModule = ../modules/services/private-store.nix;
  hostIntegration = assert vermissian.services.privateStore.enable;
  assert vermissian.services.privateStore.imagePath == "/home/strongbox/private-store.img";
  assert vermissian.services.privateStore.mountPath == "/run/strongbox";
  assert vermissian.users.users.strongbox.uid == 1024;
  assert vermissian.fileSystems."/mnt/backup".fsType == "nfs";
  assert builtins.elem "x-systemd.automount" vermissian.fileSystems."/mnt/backup".options; true;
  testPassphrase = "vm-private-store-test-passphrase";
  privatePath = "/var/lib/strongbox/private";
  socketPath = "${privatePath}/postgresql/socket";
  sessionSocket = "${privatePath}/tmux/socket";
  backupImage = "/mnt/backup/private-store.img";
  previousBackupImage = "/mnt/backup/private-store.img.previous";
  createCommand = "printf '${testPassphrase}\\n${testPassphrase}\\n' | strongbox create";
  openCommand = "printf '${testPassphrase}\\n' | strongbox open";
  closedAssertions = "test ! -e /dev/mapper/strongbox && ! mountpoint -q ${privatePath} && ! systemctl is-active --quiet postgresql.target && ! systemctl is-active --quiet postgresql.service && ! systemctl is-active --quiet postgresql-setup.service && ! systemctl is-active --quiet strongbox-session.service";
  mkNode = {
    mountPath ? privatePath,
    failPostgresql ? false,
    nfsServer ? false,
  }: {
    lib,
    pkgs,
    ...
  }: {
    imports = [privateStoreModule];
    services.privateStore = {
      enable = true;
      imagePath = "/var/lib/strongbox/image.img";
      inherit mountPath;
    };
    users.users.intruder = {
      isNormalUser = true;
    };
    users.users.socketIntruder = {
      isNormalUser = true;
      extraGroups = ["private-store-socket"];
    };
    virtualisation.memorySize = 2048;
    environment.systemPackages = [pkgs.nfs-utils];
    services.nfs.server.enable = nfsServer;
    services.nfs.server.exports = lib.mkIf nfsServer "/export *(rw,fsid=0,no_subtree_check,no_root_squash)";
    systemd.mounts = lib.mkIf nfsServer [
      {
        what = "localhost:/";
        where = "/mnt/backup";
        type = "nfs";
        options = "vers=4.2";
      }
    ];
    systemd.automounts = lib.mkIf nfsServer [
      {
        wantedBy = ["multi-user.target"];
        where = "/mnt/backup";
      }
    ];
    systemd.tmpfiles.rules = lib.mkIf nfsServer ["d /export 0777 root root - -"];
    systemd.services.postgresql.serviceConfig.ExecStart = lib.mkIf failPostgresql (lib.mkForce "${pkgs.coreutils}/bin/false");
  };
in
  assert hostIntegration;
    pkgs.testers.runNixOSTest {
      name = "private-store-lifecycle";

      nodes = {
        machine = mkNode {nfsServer = true;};
        peerFixture = mkNode {};
        mountFailure = mkNode {mountPath = "/var/lib/strongbox/mount-target";};
        unitFailure = mkNode {failPostgresql = true;};
      };

      testScript = ''
        start_all()

        machine.succeed("! systemctl is-active --quiet postgresql.target && ! systemctl is-active --quiet postgresql.service && ! systemctl is-active --quiet postgresql-setup.service")
        machine.succeed("test \"$(id -u strongbox)\" = 1024")
        machine.succeed("${createCommand}")
        machine.succeed("test -f /var/lib/strongbox/image.img")
        machine.succeed("test \"$(stat -c '%a:%u:%g' /var/lib/strongbox)\" = 700:1024:1024")
        machine.succeed("test \"$(stat -c '%a:%u:%g' /var/lib/strongbox/image.img)\" = 600:1024:1024")
        machine.succeed("cryptsetup luksDump /var/lib/strongbox/image.img | grep -E 'Version:[[:space:]]+2'")
        machine.succeed("cryptsetup luksDump /var/lib/strongbox/image.img | grep -E 'PBKDF:[[:space:]]+argon2id'")
        machine.fail("printf 'different\\ndifferent\\n' | strongbox create")
        machine.succeed("${closedAssertions}")

        machine.fail("printf 'wrong-passphrase\\n' | strongbox open")
        machine.succeed("${closedAssertions}")

        machine.succeed("${openCommand}")
        machine.succeed("mountpoint -q ${privatePath}")
        machine.succeed("test \"$(blkid -s TYPE -o value /dev/mapper/strongbox)\" = ext4")
        machine.succeed("systemctl is-active --quiet postgresql.target")
        machine.succeed("systemctl is-active --quiet postgresql.service")
        machine.succeed("systemctl is-active --quiet postgresql-setup.service")
        machine.succeed("systemctl is-active --quiet strongbox-session.service")
        machine.succeed("systemctl show -p LimitCORE --value postgresql.service | grep -Fx 0")
        machine.succeed("test \"$(stat -c '%a' ${privatePath})\" = 700")
        machine.succeed("runuser -u strongbox -- tmux -S ${sessionSocket} has-session -t private-shell")
        machine.succeed("runuser -u strongbox -- touch ${privatePath}/owner-check && chmod 0600 ${privatePath}/owner-check")
        machine.succeed("runuser -u strongbox -- test -r ${privatePath}/owner-check")
        machine.succeed("runuser -u strongbox -- ${pkgs.postgresql_17}/bin/psql -h ${socketPath} -U strongbox -d strongbox -Atqc 'select 1' | grep -Fx 1")
        machine.succeed("runuser -u strongbox -- ${pkgs.postgresql_17}/bin/psql -h ${socketPath} -U postgres -d postgres -Atqc 'show data_directory' | grep -Fx ${privatePath}/postgresql/data")
        machine.succeed("runuser -u strongbox -- ${pkgs.postgresql_17}/bin/psql -h ${socketPath} -U postgres -d postgres -Atqc 'show log_directory' | grep -Fx ${privatePath}/postgresql/log")
        machine.succeed("runuser -u strongbox -- ${pkgs.postgresql_17}/bin/psql -h ${socketPath} -U postgres -d postgres -Atqc 'show unix_socket_directories' | grep -Fx ${socketPath}")
        machine.succeed("runuser -u strongbox -- ${pkgs.postgresql_17}/bin/psql -h ${socketPath} -U strongbox -d strongbox -Atqc \"select default_version from pg_available_extensions where name = 'vector'\" | grep -E '^[0-9]'")
        machine.succeed("test -S ${socketPath}/.s.PGSQL.5432")
        directory_status, directory_output = machine.execute("runuser -u intruder -- ls ${privatePath} 2>&1")
        assert directory_status != 0
        assert "Permission denied" in directory_output
        file_status, file_output = machine.execute("runuser -u intruder -- cat ${privatePath}/owner-check 2>&1")
        assert file_status != 0
        assert "Permission denied" in file_output
        session_status, session_output = machine.execute("runuser -u intruder -- tmux -S ${sessionSocket} has-session 2>&1")
        assert session_status != 0
        assert "Permission denied" in session_output
        socket_status, socket_output = machine.execute("runuser -u intruder -- ${pkgs.postgresql_17}/bin/psql -h ${socketPath} -U strongbox -d strongbox -Atqc 'select 1' 2>&1")
        assert socket_status != 0
        assert "Permission denied" in socket_output
        machine.succeed("tail -f /dev/null | runuser -u strongbox -- env TERM=xterm-256color ${pkgs.util-linux}/bin/script -q -c '${pkgs.tmux}/bin/tmux -S ${sessionSocket} attach-session -t private-shell' /dev/null >/tmp/strongbox-attached-client.log 2>&1 & echo $! >/run/strongbox-attached-client.pid")
        machine.succeed("for attempt in $(seq 1 50); do tmux -S ${sessionSocket} list-clients -F '#{session_name}' | grep -Fx private-shell && exit 0; sleep 0.1; done; exit 1")
        machine.succeed("systemctl stop mnt-backup.automount")
        machine.succeed("mkdir -p /mnt/backup && chown strongbox:strongbox /mnt/backup && chmod 0700 /mnt/backup")
        close_status, close_output = machine.execute("strongbox close 2>&1")
        assert close_status != 0
        assert "locked, backup failed" in close_output
        machine.succeed("${closedAssertions}")
        machine.succeed("! kill -0 $(cat /run/strongbox-attached-client.pid)")

        machine.wait_for_unit("nfs-server.service")
        machine.succeed("mount -t tmpfs -o mode=0777,size=512M tmpfs /export && exportfs -ra")
        machine.succeed("systemctl start mnt-backup.automount")
        machine.succeed("test \"$(findmnt -n -o FSTYPE --mountpoint /mnt/backup)\" = autofs")
        machine.succeed("${openCommand}")
        close_status, close_output = machine.execute("strongbox close 2>&1")
        assert close_status == 0, close_output
        machine.succeed("findmnt -n -o FSTYPE --mountpoint /mnt/backup | grep -E '^(nfs|nfs4)$'")
        machine.succeed("runuser -u strongbox -- touch /mnt/backup/uid-test && rm /mnt/backup/uid-test")
        machine.succeed("test -f ${backupImage}")
        machine.succeed("cryptsetup luksDump ${backupImage} | grep -E 'Version:[[:space:]]+2'")
        machine.succeed("test ! -e ${previousBackupImage}")
        machine.succeed("test \"$(stat -c '%a:%u' ${backupImage})\" = 600:1024")
        machine.succeed("stat -c '%i' ${backupImage} > /run/strongbox-first-backup-inode")
        machine.succeed("${openCommand}")
        machine.succeed("used=$(du -B1 ${backupImage} | cut -f1); mount -o remount,size=$((used + 1048576)) /export")
        interrupted_status, interrupted_output = machine.execute("strongbox close 2>&1")
        assert interrupted_status != 0
        assert "locked, backup failed" in interrupted_output
        machine.succeed("${closedAssertions}")
        machine.succeed("test \"$(stat -c '%i' ${backupImage})\" = \"$(cat /run/strongbox-first-backup-inode)\"")
        machine.succeed("test -z \"$(find /mnt/backup -maxdepth 1 -name '.private-store.img.*' -print -quit)\"")
        machine.succeed("mount -o remount,size=512M /export")
        machine.succeed("${openCommand}")
        machine.succeed("strongbox close")
        machine.succeed("test -f ${previousBackupImage}")
        machine.succeed("test \"$(stat -c '%i' ${previousBackupImage})\" = \"$(cat /run/strongbox-first-backup-inode)\"")
        machine.succeed("test \"$(stat -c '%i' ${backupImage})\" != \"$(cat /run/strongbox-first-backup-inode)\"")
        machine.succeed("cp ${backupImage} /var/lib/strongbox/image.img.restored && chown strongbox:strongbox /var/lib/strongbox/image.img.restored && chmod 0600 /var/lib/strongbox/image.img.restored && mv /var/lib/strongbox/image.img.restored /var/lib/strongbox/image.img")
        machine.succeed("${openCommand}")
        machine.succeed("runuser -u strongbox -- ${pkgs.postgresql_17}/bin/psql -h ${socketPath} -U strongbox -d strongbox -Atqc 'select 1' | grep -Fx 1")

        peerFixture.succeed("${createCommand}")
        peerFixture.succeed("${openCommand}")
        peerFixture.succeed("runuser -u strongbox -- ${pkgs.postgresql_17}/bin/psql -h ${socketPath} -U postgres -d postgres -c 'CREATE ROLE \"socketIntruder\" LOGIN'")
        peerFixture.succeed("chmod 0711 /var/lib/strongbox ${privatePath} ${privatePath}/postgresql")
        peerFixture.succeed("runuser -u socketIntruder -- test -S ${socketPath}/.s.PGSQL.5432")
        peer_status, peer_output = peerFixture.execute("runuser -u socketIntruder -- ${pkgs.postgresql_17}/bin/psql -h ${socketPath} -U socketIntruder -d strongbox -Atqc 'select 1' 2>&1")
        assert peer_status != 0
        assert "Peer authentication failed" in peer_output
        peer_close_status, peer_close_output = peerFixture.execute("strongbox close 2>&1")
        assert peer_close_status != 0
        assert "locked, backup failed" in peer_close_output
        peerFixture.succeed("${closedAssertions}")

        mountFailure.succeed("${createCommand}")
        mountFailure.succeed("rmdir /var/lib/strongbox/mount-target && touch /var/lib/strongbox/mount-target")
        mount_status, mount_output = mountFailure.execute("${openCommand} 2>&1")
        assert mount_status != 0
        assert "unable to mount encrypted filesystem" in mount_output
        mountFailure.succeed("test ! -e /dev/mapper/strongbox && ! mountpoint -q /var/lib/strongbox/mount-target && test -f /var/lib/strongbox/mount-target && ! systemctl is-active --quiet postgresql.service && ! systemctl is-active --quiet strongbox-session.service")

        unitFailure.succeed("${createCommand}")
        unitFailure.fail("${openCommand}")
        unitFailure.succeed("${closedAssertions}")
      '';
    }
