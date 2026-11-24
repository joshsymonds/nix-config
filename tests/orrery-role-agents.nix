# Checks that every agent named in the rendered ~/.config/orrery/roles.toml is a
# regular file in the built home, under ~/.claude/agents, and that each such file
# resolves to the role-agent store file for that agent. The roles are read from
# the rendered file, so a role added later is checked without touching this
# check. The report goes to $out, one line per role.
{
  pkgs,
  homeFiles,
}: let
  checker = pkgs.writeText "orrery-role-agents.py" ''
    import os
    import sys
    import tomllib

    home = sys.argv[1]

    def die(message):
        sys.exit(f"orrery-role-agents: {message}")

    roles_path = os.path.join(home, ".config/orrery/roles.toml")
    if not os.path.isfile(roles_path):
        die(f"{roles_path} is missing")
    try:
        with open(roles_path, "rb") as f:
            roles = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        die(f"{roles_path} is not valid TOML: {e}")
    if not roles:
        die(f"{roles_path} names no role")

    for role, agent in roles.items():
        if not isinstance(agent, str) or not agent or "/" in agent:
            die(f"role {role} does not name an agent: {agent!r}")
        rel = f".claude/agents/{agent}.md"
        path = os.path.join(home, rel)
        if not os.path.isfile(path):
            die(f"role {role} names agent {agent}, but {rel} is not a regular file")
        resolved = os.path.realpath(path)
        name = os.path.basename(resolved)
        expected = f"role-agent-{agent}.md"
        if not os.path.isfile(resolved) or len(name) < 34 or name[32] != "-" or name[33:] != expected:
            die(f"role {role} names agent {agent}, but {rel} resolves to {resolved}, not a regular store file named <hash>-{expected}")
        print(f"{role} = {agent} -> {rel} -> {resolved}")
  '';
in
  pkgs.runCommand "orrery-role-agents-check" {
    nativeBuildInputs = [pkgs.python3];
  } ''
    set -eu
    python3 -I ${checker} ${homeFiles} > $out
  ''
