{
  lib,
  python3Packages,
  fetchFromGitHub,
  fetchPypi,
}:
with python3Packages; let
  # Custom markdown-to-confluence package (not in nixpkgs). 0.6.3 is the
  # newest release whose requirements nixpkgs satisfies; 0.6.4 needs
  # pymdown-extensions>=12 and cattrs>=26.2.
  markdown-to-confluence = buildPythonPackage rec {
    pname = "markdown-to-confluence";
    version = "0.6.3";
    src = fetchPypi {
      pname = "markdown_to_confluence";
      inherit version;
      hash = "sha256-wfSaUoIMM2qmo6n9jRUwAlb4Q9lx/lNk8V9fa0Z23TI=";
    };
    pyproject = true;
    build-system = [setuptools];
    dependencies = [
      cattrs
      lxml
      markdown
      orjson
      pathspec
      pymdown-extensions
      pyyaml
      requests
      truststore
    ];
    doCheck = false;
  };
in
  buildPythonApplication rec {
    pname = "mcp-atlassian";
    version = "0.23.1";

    src = fetchFromGitHub {
      owner = "sooperset";
      repo = "mcp-atlassian";
      rev = "v${version}";
      hash = "sha256-zbBsEBEfSvsS7dTbbvx2HG2GQhxGtvwVpYf4JPZVCKw=";
    };

    pyproject = true;

    # The GitHub tarball has no .git; without this the dist metadata falls
    # back to uv-dynamic-versioning's 0.0.0.
    env.UV_DYNAMIC_VERSIONING_BYPASS = version;

    build-system = [
      hatchling
      uv-dynamic-versioning
    ];

    dependencies =
      [
        anyio
        atlassian-python-api
        beautifulsoup4
        cachetools
        click
        fakeredis
        fastmcp
        httpx
        keyring
        markdown
        markdown-to-confluence
        markdownify
        mcp
        pydantic
        python-dateutil
        python-dotenv
        starlette
        thefuzz
        trio
        truststore
        unidecode
        urllib3
        uvicorn
      ]
      ++ requests.optional-dependencies.socks;

    pythonRelaxDeps = [
      # Upstream caps fakeredis <2.35 only because 2.35.0 renamed
      # FakeConnection, which broke pydocket. Neither mcp-atlassian nor
      # nixpkgs' fastmcp imports fakeredis or pulls in pydocket.
      "fakeredis"
    ];

    # Type stubs upstream lists as runtime dependencies; not needed to run.
    pythonRemoveDeps = [
      "types-python-dateutil"
      "types-cachetools"
    ];

    pythonImportsCheck = ["mcp_atlassian"];

    # Upstream's suite needs live Atlassian instances or pytest plugins.
    doCheck = false;

    meta = with lib; {
      description = "MCP server for Atlassian products (Jira and Confluence)";
      homepage = "https://github.com/sooperset/mcp-atlassian";
      license = licenses.mit;
      maintainers = [];
      mainProgram = "mcp-atlassian";
    };
  }
