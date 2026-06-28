#!/usr/bin/env python3
"""PreToolUse:Bash guard against irreversible, no-undo destruction.

Wired as a PreToolUse hook on the Bash tool. Reads the hook JSON on stdin;
if the command is a destructive operation with NO git/checkpoint safety net
(database drops/truncates/wipes, disk formatting, unbounded `rm -rf`, the
destructive git family), it returns permissionDecision "deny" so the call
never executes.

WHY deny and not ask: this profile runs in bypassPermissions mode. A
PreToolUse `deny` still blocks under bypass ("bypass skips only interactive
confirmations, not system hooks"), but an `ask` IS an interactive
confirmation, so bypass swallows it — an ask-tier guard would be a silent
no-op here. Deny is the only tier that actually fires.

Escape hatch: the operator runs the command themselves (the hook only gates
Claude's Bash tool, not their own shell), or re-issues it to Claude prefixed
with `CLAUDE_ALLOW_DESTRUCTIVE=1` for a one-shot bypass.

SCOPE — this is a speed-bump against reflexive/accidental destruction, NOT an
adversarial sandbox. It only sees the literal Bash argv, so it does NOT catch:
SQL typed into an interactive psql/mongosh REPL, SQL sourced from a file or
heredoc (`psql < f.sql`), queries issued by application/ORM code, or anything
run through an MCP database tool (those bypass Bash entirely and would need a
separate tool-name matcher). It reliably catches the one-shot `-c"…"`/
subcommand forms, which is the bulk of what an agent types.

FAIL-OPEN: any parse error or unexpected input -> allow. A guard bug must
never block `git status`. Input on stdin: Claude Code hook JSON. Output:
silent (exit 0) to allow; JSON permissionDecision on stdout to deny.
"""
import json
import os
import re
import sys
from typing import NoReturn, cast

BYPASS_ENV = "CLAUDE_ALLOW_DESTRUCTIVE"

# A command separator or start-of-line, optionally followed by inline env
# assignments (FOO=bar) and `sudo`, then an optional absolute path prefix
# (/usr/bin/). Used to anchor a bare verb at an actual command position so we
# don't fire on it appearing inside an `echo "..."`/`grep '...'` argument.
CMD_START = r"(?:^|[\n;&|(`]|&&|\|\|)\s*(?:[A-Za-z_]\w*=\S*\s+)*(?:sudo\s+)?(?:\S*/)?"

# A SQL client binary must be present before we treat raw SQL keywords as
# destructive — otherwise `echo "DROP TABLE x"` would false-positive.
SQL_CLIENT = re.compile(
    r"\b(psql|mysql|mariadb|sqlite3|sqlcmd|sqlplus|cockroach|"
    + r"clickhouse-client|clickhouse|cqlsh|mongosh|mongo|influx)\b",
    re.I,
)


def allow() -> NoReturn:
    # No stdout + exit 0 == defer to the normal permission flow (i.e. allow,
    # since this profile is bypassPermissions).
    sys.exit(0)


def deny(what: str) -> NoReturn:
    reason = (
        f"{what} is blocked by the destructive-command guard: it is "
        "irreversible and has no git or checkpoint to undo it. If the user "
        "explicitly wants this, let them run it themselves, or re-issue the "
        f"command prefixed with {BYPASS_ENV}=1 once they've confirmed."
    )
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    sys.exit(0)


# --- filesystem -----------------------------------------------------------

_DANGEROUS_RM_TARGET = re.compile(
    r"""^(?:
        /                                   # root
      | /\*                                 # everything under root
      | ~ | ~/ | ~/\*                        # home
      | \$\{?HOME\}?/?\*?                    # $HOME / ${HOME}/
      | \. | \.\.                            # cwd / parent
      | \*                                  # bare top-level glob
      | \$\{?\w+\}?/                         # $VAR/  (empty var -> /)
      | /(?:etc|usr|var|bin|boot|lib|lib64|opt|root|home|dev|sys|proc|nix|sbin|srv)(?:/\*?)?/?
      | /(?:home|Users)/[^/]+/?             # an entire user home
    )$""",
    re.X,
)


def _rm_target_dangerous(t: str) -> bool:
    t = t.strip().strip('"').strip("'")
    return bool(t) and bool(_DANGEROUS_RM_TARGET.match(t))


def dangerous_rm(cmd: str) -> bool:
    """True if an `rm` with recursive+force flags targets a filesystem root,
    home, an entire user dir, a bare glob, or an empty-variable path. Scoped
    removals (project subdirs, build dirs, /tmp/...) are intentionally allowed.
    """
    for m in re.finditer(CMD_START + r"rm\s+(?P<rest>[^\n;&|()`]*)", cmd, re.I):
        tokens = m.group("rest").split()
        flags = [t for t in tokens if t.startswith("-")]
        targets = [t for t in tokens if not t.startswith("-")]
        joined = "".join(f.lstrip("-") for f in flags)
        has_r = "r" in joined or "R" in joined or any("recursive" in f for f in flags)
        has_f = "f" in joined or any("force" in f for f in flags)
        if has_r and has_f and any(_rm_target_dangerous(t) for t in targets):
            return True
    return False


_DISK = re.compile(CMD_START + r"(?:mkfs(?:\.\w+)?|wipefs|blkdiscard)\b", re.I)
_DD_DEV = re.compile(r"\bdd\b[^\n;&|]*\bof=\s*['\"]?/dev/", re.I)
_REDIR_DEV = re.compile(r">\s*/dev/(?:sd|nvme|vd|mmcblk|disk|hd)", re.I)


def disk_format(cmd: str) -> bool:
    return bool(_DISK.search(cmd) or _DD_DEV.search(cmd) or _REDIR_DEV.search(cmd))


# --- git ------------------------------------------------------------------


def git_destructive(cmd: str) -> "str | None":
    if not re.search(CMD_START + r"git\b", cmd, re.I):
        return None
    if re.search(r"\breset\b[^\n;&|]*--hard", cmd, re.I):
        return "`git reset --hard`"
    if re.search(r"\bclean\b[^\n;&|]*\s-[A-Za-z]*f", cmd, re.I) and not re.search(
        r"\bclean\b[^\n;&|]*\s-[A-Za-z]*n", cmd, re.I
    ):
        return "`git clean -f`"
    if re.search(r"\bcheckout\b[^\n;&|]*\s--\s", cmd, re.I) or re.search(
        r"\bcheckout\s+\.(?:\s|$)", cmd, re.I
    ):
        return "`git checkout --` (discards working changes)"
    if re.search(r"\bgit\s+restore\b", cmd, re.I):
        staged_only = re.search(r"--staged", cmd, re.I) and not re.search(
            r"--worktree|\s-W\b", cmd, re.I
        )
        if not staged_only:
            return "`git restore` (discards working changes)"
    if re.search(r"\bbranch\b[^\n;&|]*\s-D\b", cmd, re.I):
        return "`git branch -D` (force-deletes a branch)"
    if re.search(r"\bstash\b\s+(?:drop|clear)\b", cmd, re.I):
        return "`git stash drop/clear`"
    if re.search(r"\bpush\b[^\n;&|]*(?:--force\b|\s-f\b)", cmd, re.I) and not re.search(
        r"--force-with-lease", cmd, re.I
    ):
        return "`git push --force`"
    if re.search(r"\b(?:reflog\s+expire|filter-branch|filter-repo)\b", cmd, re.I):
        return "git history rewrite"
    return None


# --- databases ------------------------------------------------------------


def _unfiltered_dml(cmd: str) -> bool:
    """A DELETE FROM / UPDATE ... SET with no WHERE clause before its
    terminator. Light parse, not substring: `DELETE FROM t WHERE id=5` passes.
    """
    for m in re.finditer(r"\b(DELETE\s+FROM|UPDATE)\b(.*?)(?:;|$)", cmd, re.I | re.S):
        seg = m.group(0)
        if re.search(r"\bWHERE\b", seg, re.I):
            continue
        if m.group(1).upper().startswith("UPDATE") and not re.search(r"\bSET\b", seg, re.I):
            continue  # not a real UPDATE statement
        return True
    return False


def db_destructive(cmd: str) -> "str | None":
    sql = bool(SQL_CLIENT.search(cmd))

    # whole-store wipes
    if sql and re.search(r"\bDROP\s+(?:DATABASE|SCHEMA)\b", cmd, re.I):
        return "`DROP DATABASE/SCHEMA`"
    if re.search(CMD_START + r"dropdb\b", cmd, re.I):
        return "`dropdb`"
    if re.search(r"\bmysqladmin\b[^\n;&|]*\bdrop\b", cmd, re.I):
        return "`mysqladmin drop`"
    if re.search(r"\b(?:redis-cli|valkey-cli)\b[^\n;&|]*\bflush(?:all|db)\b", cmd, re.I):
        return "Redis/Valkey `FLUSHALL`/`FLUSHDB`"
    if re.search(r"\b(?:redis-cli|valkey-cli)\b[^\n;&|]*\bshutdown\s+nosave\b", cmd, re.I):
        return "Redis/Valkey `SHUTDOWN NOSAVE`"
    if re.search(r"\b(?:mongosh|mongo)\b", cmd, re.I) and re.search(r"\bdropDatabase\s*\(", cmd):
        return "MongoDB `dropDatabase()`"
    if re.search(r"\baws\s+dynamodb\s+delete-table\b", cmd, re.I):
        return "DynamoDB `delete-table`"
    if re.search(r"\bgcloud\s+spanner\s+databases\s+delete\b", cmd, re.I):
        return "Spanner `databases delete`"
    if re.search(r"\bbq\s+rm\b[^\n;&|]*-r\b", cmd, re.I) and re.search(
        r"\bbq\s+rm\b[^\n;&|]*-f\b", cmd, re.I
    ):
        return "BigQuery `bq rm -r -f`"
    if re.search(r"\bcurl\b[^\n;&|]*-X\s*DELETE\b[^\n;&|]*:9200/[^_\s]", cmd, re.I):
        return "Elasticsearch `DELETE /index`"

    # table / collection / keyspace level
    if sql and re.search(r"\bTRUNCATE\b(?:\s+TABLE)?\b", cmd, re.I):
        return "`TRUNCATE`"
    if sql and re.search(r"\bDROP\s+TABLE\b", cmd, re.I):
        return "`DROP TABLE`"
    if sql and re.search(r"\bDROP\s+KEYSPACE\b", cmd, re.I):
        return "`DROP KEYSPACE`"
    if sql and re.search(r"\bALTER\s+TABLE\b[^\n;]*\bDROP\s+COLUMN\b", cmd, re.I):
        return "`ALTER TABLE ... DROP COLUMN`"
    if re.search(r"\b(?:mongosh|mongo)\b", cmd, re.I) and re.search(
        r"\.\w+\.drop\s*\(\s*\)", cmd
    ):
        return "MongoDB `collection.drop()`"
    if re.search(r"\b(?:mongosh|mongo)\b", cmd, re.I) and re.search(
        r"\.(?:deleteMany|remove)\s*\(\s*\{\s*\}\s*\)", cmd
    ):
        return "MongoDB `deleteMany({})` (empty filter)"
    if re.search(r"\bcqlsh\b[^\n]*\b(?:TRUNCATE|DROP\s+TABLE)\b", cmd, re.I):
        return "Cassandra `TRUNCATE`/`DROP TABLE`"
    if re.search(r"\bclickhouse(?:-client)?\b[^\n]*\b(?:TRUNCATE|DROP\s+TABLE)\b", cmd, re.I):
        return "ClickHouse `TRUNCATE`/`DROP TABLE`"
    if re.search(r"\binflux\b[^\n]*\bDROP\s+(?:DATABASE|MEASUREMENT|SERIES)\b", cmd, re.I):
        return "InfluxDB `DROP`"
    if re.search(r"\bcurl\b[^\n]*_delete_by_query\b", cmd, re.I):
        return "Elasticsearch `_delete_by_query`"
    if re.search(r"\bkafka-topics(?:\.sh)?\b[^\n]*--delete\b", cmd, re.I):
        return "Kafka topic `--delete`"
    if re.search(r"\bcypher-shell\b[^\n]*\bDETACH\s+DELETE\b", cmd, re.I):
        return "Neo4j `DETACH DELETE`"
    if re.search(r"\betcdctl\b[^\n]*\bdel\b[^\n]*--prefix", cmd, re.I):
        return "etcd `del --prefix`"

    # migration CLIs — always shell-invoked, so a Bash hook catches these well
    if re.search(r"\bprisma\s+migrate\s+reset\b", cmd, re.I):
        return "`prisma migrate reset`"
    if re.search(r"\b(?:rails|rake)\s+db:(?:drop|reset|schema:load)\b", cmd, re.I):
        return "`rails db:drop/reset`"
    if re.search(r"\bsequelize(?:-cli)?\s+db:drop\b", cmd, re.I):
        return "`sequelize db:drop`"
    if re.search(r"\balembic\s+downgrade\s+(?:base|-1)\b", cmd, re.I):
        return "`alembic downgrade base`"
    if re.search(r"\bknex\b[^\n]*\bmigrate:rollback\b[^\n]*--all\b", cmd, re.I):
        return "`knex migrate:rollback --all`"

    # unfiltered DML (requires a client so plain text isn't matched)
    if sql and _unfiltered_dml(cmd):
        return "`DELETE`/`UPDATE` without a `WHERE` clause"

    return None


def main() -> None:
    try:
        parsed = cast("object", json.loads(sys.stdin.read() or "{}"))
    except Exception:
        allow()
    if not isinstance(parsed, dict):
        allow()
    data = cast("dict[str, object]", parsed)
    if data.get("tool_name") != "Bash":
        allow()
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        allow()
    cmd = cast("dict[str, object]", tool_input).get("command")
    if not isinstance(cmd, str) or not cmd.strip():
        allow()

    try:
        # One-shot operator bypass: env var, or an inline `VAR=1` prefix.
        if os.environ.get(BYPASS_ENV) in ("1", "true", "yes"):
            allow()
        if re.search(CMD_START + re.escape(BYPASS_ENV) + r"=(?:1|true|yes)\b", cmd):
            allow()
        # Dry runs are always safe.
        if re.search(r"--dry[-_]run\b", cmd, re.I):
            allow()

        what = None
        if dangerous_rm(cmd):
            what = "`rm -rf` on a filesystem root / home / unscoped target"
        elif disk_format(cmd):
            what = "Formatting or overwriting a block device"
        else:
            what = git_destructive(cmd) or db_destructive(cmd)

        if what:
            deny(what)
    except Exception:
        allow()  # fail-open: a guard bug must never block ordinary work
    allow()


if __name__ == "__main__":
    main()
