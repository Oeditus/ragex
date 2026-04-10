import Config

# In development, the socket server starts by default.
# The stdio server is disabled to avoid SIGTTIN when running in background.
# Set RAGEX_STDIO=1 to enable stdio server (for testing stdio mode).
# Set RAGEX_NO_SERVER=1 to disable all MCP servers.

start_server? = !System.get_env("RAGEX_NO_SERVER")
config :ragex, :start_server, start_server?

start_stdio? = !!System.get_env("RAGEX_STDIO")
config :ragex, :start_stdio_server, start_stdio?

# You can enable verbose logging in development
config :logger, level: :debug
