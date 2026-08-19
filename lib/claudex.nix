# Shared CLIProxyAPI (claudex) coordinates. home-manager/claudex owns the
# running service; home-manager/patchbay routes chatgpt/* aliases at it.
# Kept here so the port/key/model ids can never drift between the two.
{
  port = 8317;
  apiKey = "claudex-local";
  model = "gpt-5.6-sol";
  fastModel = "gpt-5.6-luna";
}
