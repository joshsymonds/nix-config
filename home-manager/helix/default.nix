{
  lib,
  pkgs,
  ...
}: let
  lspPackages = [
    pkgs.lua-language-server
    pkgs.gopls
    pkgs.pyright
    pkgs.nil
    pkgs.typescript-language-server
    pkgs.typescript
    pkgs.vscode-langservers-extracted
    pkgs.yaml-language-server
    pkgs.terraform-ls
    pkgs.terraform
    pkgs.alejandra
  ];
in {
  programs.helix = {
    enable = true;
    defaultEditor = true;
    package = pkgs.helix;
    settings = {
      theme = "catppuccin_powerline";
      editor = {
        default-yank-register = "+";
        line-number = "relative";
        cursor-shape = {
          insert = "bar";
          normal = "block";
          select = "underline";
        };
        true-color = true;
        color-modes = true;
        lsp = {
          display-messages = true;
          display-inlay-hints = true;
        };
        statusline = {
          left = [
            "mode"
            "separator"
            "version-control"
            "separator"
            "file-name"
            "file-modification-indicator"
          ];
          center = [];
          right = [
            "diagnostics"
            "separator"
            "selections"
            "separator"
            "position-percentage"
            "position"
            "separator"
            "file-type"
          ];
          separator = " | ";
          mode = {
            normal = "[NORMAL]";
            insert = "[INSERT]";
            select = "[SELECT]";
          };
          diagnostics = ["warning" "error"];
          workspace-diagnostics = ["warning" "error"];
        };
        soft-wrap = {
          enable = true;
          wrap-at-text-width = true;
          wrap-indicator = " ";
        };
        indent-guides = {
          render = true;
          character = "╎";
          skip-levels = 1;
        };
        file-picker = {
          hidden = false;
        };
      };
      keys = {
        normal = {
          "^" = "goto_line_start";
          "$" = "goto_line_end";
          "C-h" = "jump_view_left";
          "C-l" = "jump_view_right";
          "C-j" = "jump_view_down";
          "C-k" = "jump_view_up";
          space = {
            n = "keep_primary_selection";
          };
        };
        select = {
          "^" = "goto_line_start";
          "$" = "goto_line_end";
          "C-h" = "jump_view_left";
          "C-l" = "jump_view_right";
          "C-j" = "jump_view_down";
          "C-k" = "jump_view_up";
          space = {
            n = "keep_primary_selection";
          };
        };
      };
    };

    languages = {
      language = [
        {
          name = "lua";
          scope = "source.lua";
          file-types = ["lua"];
          auto-format = true;
          "language-servers" = ["lua-language-server"];
        }
        {
          name = "go";
          scope = "source.go";
          file-types = ["go"];
          auto-format = true;
          "language-servers" = ["gopls"];
        }
        {
          name = "python";
          scope = "source.python";
          file-types = ["py" "pyi"];
          auto-format = true;
          "language-servers" = ["pyright"];
        }
        {
          name = "nix";
          scope = "source.nix";
          file-types = ["nix"];
          formatter = {
            command = "${pkgs.alejandra}/bin/alejandra";
          };
          "language-servers" = ["nil"];
        }
        {
          name = "javascript";
          scope = "source.js";
          file-types = ["js" "mjs" "cjs"];
          auto-format = true;
          "language-servers" = ["typescript-language-server"];
        }
        {
          name = "typescript";
          scope = "source.ts";
          file-types = ["ts" "tsx"];
          auto-format = true;
          "language-servers" = ["typescript-language-server"];
        }
        {
          name = "html";
          scope = "text.html.basic";
          file-types = ["html" "htm"];
          "language-servers" = ["html-ls"];
        }
        {
          name = "css";
          scope = "source.css";
          file-types = ["css" "pcss" "scss"];
          "language-servers" = ["css-ls"];
        }
        {
          name = "json";
          scope = "source.json";
          file-types = ["json"];
          "language-servers" = ["json-ls"];
        }
        {
          name = "terraform";
          scope = "source.terraform";
          file-types = ["tf" "tfvars"];
          auto-format = true;
          "language-servers" = ["terraform-ls"];
          formatter = {
            command = "${pkgs.terraform}/bin/terraform";
            args = ["fmt" "-"];
          };
        }
        {
          name = "yaml";
          scope = "source.yaml";
          auto-format = true;
          file-types = ["yaml" "yml" "helm"];
          "language-servers" = ["yaml-language-server"];
        }
      ];

      "language-server" = {
        "lua-language-server" = {
          command = "${pkgs.lua-language-server}/bin/lua-language-server";
        };
        gopls = {
          command = "${pkgs.gopls}/bin/gopls";
        };
        pyright = {
          command = "${pkgs.pyright}/bin/pyright-langserver";
          args = ["--stdio"];
        };
        nil = {
          command = "${pkgs.nil}/bin/nil";
        };
        "typescript-language-server" = {
          command = "${pkgs.typescript-language-server}/bin/typescript-language-server";
          args = ["--stdio"];
        };
        "html-ls" = {
          command = "${pkgs.vscode-langservers-extracted}/bin/vscode-html-language-server";
          args = ["--stdio"];
        };
        "css-ls" = {
          command = "${pkgs.vscode-langservers-extracted}/bin/vscode-css-language-server";
          args = ["--stdio"];
        };
        "json-ls" = {
          command = "${pkgs.vscode-langservers-extracted}/bin/vscode-json-language-server";
          args = ["--stdio"];
        };
        "terraform-ls" = {
          command = "${pkgs.terraform-ls}/bin/terraform-ls";
          args = ["serve"];
        };
        "yaml-language-server" = {
          command = "${pkgs.yaml-language-server}/bin/yaml-language-server";
          args = ["--stdio"];
          config = {
            yaml = {
              schemaStore = {enable = true;};
              format = {enable = true;};
              validate = true;
              completion = true;
              hover = true;
              schemas = {
                kubernetes = ["*.k8s.yaml" "kustomization.yaml" "**/values.yaml" "helm/*.yaml"];
              };
            };
          };
        };
      };
    };
  };

  xdg.configFile."helix/themes/catppuccin_powerline.toml".text = ''
    inherits = "catppuccin_mocha"

    "ui.statusline" = { fg = "subtext1", bg = "mantle" }
    "ui.statusline.inactive" = { fg = "surface2", bg = "mantle" }
    "ui.statusline.normal" = { fg = "crust", bg = "lavender", modifiers = ["bold"] }
    "ui.statusline.insert" = { fg = "crust", bg = "flamingo", modifiers = ["bold"] }
    "ui.statusline.select" = { fg = "crust", bg = "peach", modifiers = ["bold"] }
    "ui.statusline.separator" = { fg = "subtext0", bg = "mantle", modifiers = ["bold"] }
    "ui.virtual.indent-guide" = { fg = "surface2", modifiers = ["dim"] }
  '';

  home.packages = lib.mkAfter lspPackages;
}
