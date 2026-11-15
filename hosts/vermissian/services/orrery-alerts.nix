# Prometheus and Alertmanager on loopback. Prometheus scrapes orreryd and orrery
# serve, evaluates orrery's alert rules, and sends firing alerts to the local
# Alertmanager, which posts them to orreryd's /alerts intake.
{inputs, ...}: {
  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9090;

    ruleFiles = [(inputs.orrery + "/observability/orrery-rules.yml")];

    # The --metrics-listen addresses set in home-manager/orrery/default.nix and
    # home-manager/orrery/serve.nix.
    scrapeConfigs = [
      {
        job_name = "orreryd";
        static_configs = [{targets = ["127.0.0.1:9464"];}];
      }
      {
        job_name = "orrery-serve";
        static_configs = [{targets = ["127.0.0.1:9465"];}];
      }
    ];

    alertmanagers = [
      {
        static_configs = [{targets = ["127.0.0.1:9093"];}];
      }
    ];

    alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9093;
      # An empty cluster listen address turns off Alertmanager's cluster port.
      extraFlags = ["--cluster.listen-address="];
      configuration = {
        route = {
          receiver = "orreryd";
          group_by = ["alertname"];
          repeat_interval = "4h";
        };
        receivers = [
          {
            name = "orreryd";
            webhook_configs = [{url = "http://127.0.0.1:9464/alerts";}];
          }
        ];
      };
    };
  };
}
