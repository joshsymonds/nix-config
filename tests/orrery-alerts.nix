# Behavioural check for orrery's metrics listeners and alerting stack on
# vermissian. The check reads the orreryd-start script that orreryd's ExecStart
# names, and orrery serve's ExecStart as text. Each must pass --metrics-listen
# with a loopback address. Prometheus's and Alertmanager's ExecStart and
# ExecStartPre come from vermissian's evaluated units; the config files they
# name are checked with promtool and amtool, then read with yq and jq.
# Nothing here runs orreryd, orrery serve, Prometheus, Alertmanager or systemd.
{
  pkgs,
  vermissian,
}: let
  services = vermissian.home-manager.users.joshsymonds.systemd.user.services;
  promService = vermissian.systemd.services.prometheus.serviceConfig;
  amService = vermissian.systemd.services.alertmanager.serviceConfig;
in
  pkgs.runCommand "orrery-alerts-check" {
    nativeBuildInputs = with pkgs;
      [bash coreutils gnugrep jq yq-go]
      ++ [
        vermissian.services.prometheus.package.cli
        vermissian.services.prometheus.alertmanager.package
      ];
    # ExecStart is a list of words. orreryd's words are its start script path,
    # which keeps its context so the script is built into the sandbox. Serve's
    # words are only read as text, so its closure stays out of the build.
    orreryExecStart = builtins.concatStringsSep " " services.orreryd.Service.ExecStart;
    serveExecStart = builtins.unsafeDiscardStringContext (builtins.concatStringsSep " " services.orrery-serve.Service.ExecStart);
    # Prometheus's ExecStart keeps its context: it names the promtool-checked
    # prometheus.yml, and that build carries the rule files into the sandbox.
    # Alertmanager's ExecStartPre keeps its context for the same reason: it
    # names the amtool-checked alertmanager.yml. Alertmanager's ExecStart is
    # only read as text.
    promExecStart = promService.ExecStart;
    amExecStartPre = amService.ExecStartPre;
    amExecStart = builtins.unsafeDiscardStringContext amService.ExecStart;
  } ''
    set -euo pipefail

    CASE=setup
    fail() {
      echo "orrery-alerts check [$CASE]: $1" >&2
      exit 1
    }

    # has_listen <addr> <file>: <file> carries --metrics-listen <addr> as one
    # whole argument. The dots in addr match only dots, not any character.
    has_listen() {
      local re=''${1//./[.]}
      grep -Eq -- "(^|[[:space:]])--metrics-listen ''${re}([[:space:]]|$)" "$2"
    }

    # has_arg <regex> <file>: <regex> matches one whole argument in <file>.
    has_arg() {
      grep -Eq -- "(^|[[:space:]])$1([[:space:]]|$)" "$2"
    }

    CASE=matcher
    printf '%s\n' 'exec orreryd --sessions --metrics-listen 127.0.0.1:9464' > ok.txt
    printf '%s\n' 'exec orreryd --sessions' > missing.txt
    printf '%s\n' 'exec orreryd --metrics-listen 0.0.0.0:9464' > wildcard.txt
    printf '%s\n' 'exec orreryd --metrics-listen 127.0.0.1:9465' > port.txt
    printf '%s\n' 'exec orreryd --metrics-listen 127x0x0x1:9464' > unescaped.txt
    has_listen 127.0.0.1:9464 ok.txt || fail "a loopback flag with the expected address did not match"
    ! has_listen 127.0.0.1:9464 missing.txt || fail "a file without the flag matched"
    ! has_listen 127.0.0.1:9464 wildcard.txt || fail "a wildcard host matched"
    ! has_listen 127.0.0.1:9464 port.txt || fail "a different port matched"
    ! has_listen 127.0.0.1:9464 unescaped.txt || fail "an unescaped dot matched a non-dot"

    # orreryd's ExecStart is the store path of the orreryd-start script, which
    # holds the orreryd command line.
    CASE=orreryd
    has_listen 127.0.0.1:9464 "$orreryExecStart" || fail "orreryd-start lacks --metrics-listen 127.0.0.1:9464"
    orreryd_addr=$(grep -oE -- '--metrics-listen [^[:space:]]+' "$orreryExecStart" | cut -d' ' -f2) || fail "orreryd-start has no --metrics-listen address"

    CASE=orrery-serve
    printf '%s\n' "$serveExecStart" > serve-exec-start.txt
    has_listen 127.0.0.1:9465 serve-exec-start.txt || fail "orrery serve lacks --metrics-listen 127.0.0.1:9465"
    serve_addr=$(grep -oE -- '--metrics-listen [^[:space:]]+' serve-exec-start.txt | cut -d' ' -f2) || fail "orrery serve has no --metrics-listen address"

    # Prometheus: loopback listener, the promtool-checked config it names, and
    # that config's scrape targets, rules and Alertmanager.
    CASE=prometheus-exec-start
    printf '%s\n' "$promExecStart" > prometheus-exec-start.txt
    prom_listen=$(grep -oE -- '--web[.]listen-address=[^[:space:]]+' prometheus-exec-start.txt) || fail "Prometheus ExecStart has no --web.listen-address"
    [ "$prom_listen" = '--web.listen-address=127.0.0.1:9090' ] || fail "Prometheus listens on $prom_listen, not 127.0.0.1:9090"
    prom_config=$(grep -oE -- '--config[.]file=[^[:space:]]+' prometheus-exec-start.txt | cut -d= -f2-) || fail "Prometheus ExecStart has no --config.file"

    CASE=prometheus-config
    promtool check config "$prom_config" || fail "promtool rejects the config Prometheus's ExecStart names"
    yq -o json "$prom_config" > prometheus.json || fail "cannot read Prometheus's config as YAML"

    CASE=scrape-targets
    printf '%s\n' "orreryd $orreryd_addr" "orrery-serve $serve_addr" | sort > expected-targets.txt
    jq -r '.scrape_configs[] | "\(.job_name) \(.static_configs[].targets[])"' prometheus.json | sort > scrape-targets.txt
    cmp -s expected-targets.txt scrape-targets.txt || fail "scrape targets are not the two --metrics-listen addresses, one per job"

    CASE=alertmanagers
    printf '%s\n' '127.0.0.1:9093' > expected-alertmanagers.txt
    jq -r '.alerting.alertmanagers[].static_configs[].targets[]' prometheus.json > alertmanagers.txt || fail "cannot read Prometheus's alertmanagers"
    cmp -s expected-alertmanagers.txt alertmanagers.txt || fail "Prometheus does not send alerts to exactly 127.0.0.1:9093"

    CASE=rules
    [ "$(jq -r '.rule_files | length' prometheus.json)" = 1 ] || fail "Prometheus does not load exactly one rules file"
    rules_file=$(jq -r '.rule_files[0]' prometheus.json) || fail "cannot read Prometheus's rule file"
    # The rule file is a checked symlink to the source file; resolve it to the
    # source's path and require observability/orrery-rules.yml inside a source.
    case "$(readlink -f "$rules_file")" in
      */observability/orrery-rules.yml) ;;
      *) fail "Prometheus's rules file is not orrery's observability/orrery-rules.yml" ;;
    esac
    yq -o json "$rules_file" > rules.json || fail "cannot read the rules file as YAML"
    jq -r '.groups[].rules[] | select(has("alert")) | .alert' rules.json | sort > alerts.txt
    printf '%s\n' OrreryCPUHigh OrreryHolderLost OrreryPushFailing OrreryStartSlow OrreryWriterStalled | sort > expected-alerts.txt
    cmp -s expected-alerts.txt alerts.txt || fail "the rules file does not hold orrery's five alerts"

    # Alertmanager: loopback listener, cluster port off, and the amtool-checked
    # config its ExecStartPre names.
    CASE=alertmanager-exec-start
    printf '%s\n' "$amExecStart" > alertmanager-exec-start.txt
    printf '%s\n' "$amExecStartPre" > alertmanager-exec-start-pre.txt
    am_listen=$(grep -oE -- '--web[.]listen-address[= ][^[:space:]]+' alertmanager-exec-start.txt) || fail "Alertmanager ExecStart has no --web.listen-address"
    [ "$am_listen" = '--web.listen-address 127.0.0.1:9093' ] || fail "Alertmanager listens on $am_listen, not 127.0.0.1:9093"
    has_arg '--cluster[.]listen-address=' alertmanager-exec-start.txt || fail "Alertmanager ExecStart lacks an empty --cluster.listen-address= that turns its cluster port off"

    CASE=alertmanager-config
    am_config=$(grep -oE -- "-i '[^']+'" alertmanager-exec-start-pre.txt | cut -d "'" -f2) || fail "Alertmanager ExecStartPre names no envsubst -i config"
    amtool check-config "$am_config" || fail "amtool rejects the config Alertmanager's ExecStartPre names"
    yq -o json "$am_config" > alertmanager.json || fail "cannot read Alertmanager's config as YAML"
    jq -e '.route.group_by == ["alertname"]' alertmanager.json > /dev/null || fail "Alertmanager does not group by alertname"
    jq -e '.route.repeat_interval == "4h"' alertmanager.json > /dev/null || fail "Alertmanager does not repeat every 4h"
    jq -e '.route.receiver as $r | (.receivers | length) == 1 and ([.receivers[] | select(.name == $r) | .webhook_configs[].url] == ["http://127.0.0.1:9464/alerts"])' alertmanager.json > /dev/null || fail "the one receiver does not post to http://127.0.0.1:9464/alerts"

    touch $out
  ''
