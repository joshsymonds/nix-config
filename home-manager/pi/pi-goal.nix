{
  pkgs,
  nodeModules,
}: let
  piGoalSource = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@narumitw/pi-goal/-/pi-goal-0.54.13.tgz";
    hash = "sha256-gC58I5R2J3JfXGhnsI6u4E0TBp8L10G5xDDrojMDRvU=";
  };

  piTuiKit = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@narumitw/pi-tui-kit/-/pi-tui-kit-0.59.0.tgz";
    hash = "sha256-dMzOHA7jxKShvU2okzNt7qRNm/5ONa+05ZkcfVTALbI=";
  };

  grokMermaid = pkgs.fetchzip {
    url = "https://registry.npmjs.org/grok-mermaid/-/grok-mermaid-0.2.3.tgz";
    hash = "sha256-tT9tKcotpywP98aI4H8AJZa6cikj9adGFZpialQ0Dxk=";
  };

  highlightJs = pkgs.fetchzip {
    url = "https://registry.npmjs.org/highlight.js/-/highlight.js-11.12.0.tgz";
    hash = "sha256-fcEJdFLzFkMR1rlm9sPVCr6A8YhUgm6+JNlLjMIrHk0=";
  };
in
  pkgs.runCommand "pi-goal-0.54.13" {} ''
    cp -r ${piGoalSource} $out
    chmod -R u+w $out
    patch -p1 -d $out < ${./pi-goal-goal-end.patch}
    mkdir -p $out/node_modules/@narumitw
    ln -s ${piTuiKit} $out/node_modules/@narumitw/pi-tui-kit
    ln -s ${grokMermaid} $out/node_modules/grok-mermaid
    ln -s ${highlightJs} $out/node_modules/highlight.js
    ln -s ${nodeModules}/typebox $out/node_modules/typebox
  ''
