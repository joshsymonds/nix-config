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
    users.users.remoteUser = {
      isNormalUser = true;
      extraGroups = ["wheel"];
    };
    users.users.socketIntruder = {
      isNormalUser = true;
      extraGroups = ["private-store-socket"];
    };
    virtualisation.memorySize = 2048;
    environment.systemPackages = [pkgs.nfs-utils pkgs.openssh];
    services.openssh = {
      enable = true;
      settings.PermitRootLogin = "no";
    };
    security.sudo.wheelNeedsPassword = false;
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
        remoteSession = mkNode {nfsServer = true;};
      };

      testScript = ''
        start_all()

        remoteSession.wait_for_unit("nfs-server.service")
        remoteSession.succeed("mount -t tmpfs -o mode=0777,size=1536M tmpfs /export && exportfs -ra")
        remoteSession.succeed("systemctl start mnt-backup.automount")
        remoteSession.succeed("ssh-keygen -q -t ed25519 -N \"\" -f /run/strongbox-test-key && install -d -o remoteUser -g users -m 0700 /home/remoteUser/.ssh && install -o remoteUser -g users -m 0600 /run/strongbox-test-key.pub /home/remoteUser/.ssh/authorized_keys && systemctl restart sshd.service")
        remoteSession.succeed("runuser -u remoteUser -- sudo -n id -u | grep -Fx 0")
        remoteSession.succeed("ssh -i /run/strongbox-test-key -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no remoteUser@localhost 'test \"$(id -u)\" != 0'")
        remoteSession.succeed("${createCommand}")
        remoteSession.succeed("${openCommand}")
        upload_status, upload_output = remoteSession.execute("printf 'first upload\\n' | ssh -i /run/strongbox-test-key -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no remoteUser@localhost strongbox-put uploaded.txt 2>&1")
        assert upload_status == 0, upload_output
        remoteSession.succeed("test \"$(cat ${privatePath}/uploaded.txt)\" = 'first upload' && test \"$(stat -c '%u:%g:%a' ${privatePath}/uploaded.txt)\" = 1024:1024:600")
        separator_status, separator_output = remoteSession.execute("printf 'invalid\\n' | ssh -i /run/strongbox-test-key -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no remoteUser@localhost strongbox-put '../outside' 2>&1")
        assert separator_status != 0, separator_output
        remoteSession.succeed("test ! -e /run/outside")
        overwrite_status, overwrite_output = remoteSession.execute("printf 'replacement\\n' | ssh -i /run/strongbox-test-key -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no remoteUser@localhost strongbox-put uploaded.txt 2>&1")
        assert overwrite_status != 0, overwrite_output
        remoteSession.succeed("test \"$(cat ${privatePath}/uploaded.txt)\" = 'first upload'")
        remoteSession.succeed("test -d ${privatePath}/tmp")
        remoteSession.succeed("""cat > ${privatePath}/.bash_profile <<'PROFILE'
        export PRIVATE_STORE_PROFILE=loaded
        printf '%s|%s|%s|%s\\n' \"$HOME\" \"$TMPDIR\" \"$PRIVATE_STORE_PROFILE\" \"$(ulimit -c)\" >> \"$HOME/session-environment\"
        PROFILE
        """)
        remoteSession.succeed("install -d -o strongbox -g strongbox -m 0700 /run/strongbox-run-test; rm -f /run/strongbox-run-test/started /run/strongbox-run-test/release /run/strongbox-run-test/result /run/strongbox-run-output /run/strongbox-close-output /run/strongbox-close-status")
        remoteSession.succeed("""cat > /run/strongbox-run-command <<'RUN'
        #!${pkgs.bash}/bin/bash
        touch /run/strongbox-run-test/started
        while [ ! -e /run/strongbox-run-test/release ]; do sleep 0.1; done
        printf '%s|%s|%s|%s\\n' \"$(id -u)\" \"$HOME\" \"$TMPDIR\" \"$PRIVATE_STORE_PROFILE\" > /run/strongbox-run-test/result
        RUN
        chmod 0755 /run/strongbox-run-command""")
        remoteSession.succeed("(ssh -i /run/strongbox-test-key -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no remoteUser@localhost 'sudo -n strongbox run -- /run/strongbox-run-command' </dev/null > /run/strongbox-run-output 2>&1 & echo $! > /run/strongbox-run-ssh.pid)")
        remoteSession.succeed("for attempt in $(seq 1 100); do [ -e /run/strongbox-run-test/started ] && exit 0; sleep 0.1; done; cat /run/strongbox-run-output; exit 1")
        remoteSession.succeed("(strongbox close; echo $? > /run/strongbox-close-status) > /run/strongbox-close-output 2>&1 </dev/null & echo $! > /run/strongbox-close.pid; sleep 1; kill -0 $(cat /run/strongbox-close.pid) && mountpoint -q ${privatePath} && test -e /dev/mapper/strongbox")
        remoteSession.succeed("touch /run/strongbox-run-test/release; for attempt in $(seq 1 100); do [ -f /run/strongbox-close-status ] && break; sleep 0.1; done; test \"$(cat /run/strongbox-close-status)\" = 0; grep -Fx '1024|${privatePath}|${privatePath}/tmp|loaded' /run/strongbox-run-test/result")
        remoteSession.succeed("${closedAssertions}")
        root_ssh_status, root_ssh_output = remoteSession.execute("ssh -i /run/strongbox-test-key -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@localhost true 2>&1")
        assert root_ssh_status != 0, root_ssh_output
        remote_status, remote_output = remoteSession.execute("(sleep 1; printf '${testPassphrase}\\n'; sleep 8; printf '\\002d'; sleep 1; printf 'y\\n') | TERM=xterm-256color ssh -tt -i /run/strongbox-test-key -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no remoteUser@localhost strongbox 2>&1")
        assert remote_status == 0, remote_output
        assert "Passphrase:" in remote_output, remote_output
        assert "Close strongbox?" in remote_output, remote_output
        remoteSession.succeed("${openCommand}")
        remoteSession.succeed("for attempt in $(seq 1 50); do [ \"$(wc -l < ${privatePath}/session-environment)\" -ge 2 ] && break; sleep 0.1; done; grep -Fx '${privatePath}|${privatePath}/tmp|loaded|0' ${privatePath}/session-environment | wc -l | grep -Fx 2")
        remoteSession.succeed("test ! -e ${privatePath}/.bash_history")
        remote_session_status, remote_session_output = remoteSession.execute("runuser -u intruder -- tmux -S ${sessionSocket} has-session 2>&1")
        assert remote_session_status != 0
        assert "Permission denied" in remote_session_output, remote_session_output
        remoteSession.succeed("strongbox close")
        remoteSession.succeed("${closedAssertions}")
        locked_run_status, locked_run_output = remoteSession.execute("ssh -i /run/strongbox-test-key -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no remoteUser@localhost 'sudo -n strongbox run -- true' 2>&1")
        assert locked_run_status != 0, locked_run_output
        assert "store is locked" in locked_run_output.lower(), locked_run_output
        locked_upload_status, locked_upload_output = remoteSession.execute("printf 'locked\\n' | ssh -i /run/strongbox-test-key -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no remoteUser@localhost strongbox-put locked.txt 2>&1")
        assert locked_upload_status != 0, locked_upload_output
        assert 'locked' in locked_upload_output.lower(), locked_upload_output
        remoteSession.succeed("test ! -e ${privatePath}/locked.txt")

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
