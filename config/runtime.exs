import Config

# Runtime Configuration
# This file is executed after compilation, allowing dynamic configuration

# Auto-analyze directories on startup
# Add directories that should be automatically analyzed when the application starts
# Example:
#   config :ragex, :auto_analyze_dirs, [
#     "/path/to/project1",
#     "/path/to/project2"
#   ]
dirs = "RAGEX_AUTO_ANALYZE_DIRS" |> System.get_env("") |> String.split(":", trim: true)

config :ragex, :auto_analyze_dirs, dirs

# You can also set this via config files in specific environments:
# config :ragex, :auto_analyze_dirs, [
#   "/opt/Proyectos/Ammotion/ragex"
# ]

# AI Provider API Keys Configuration (Phase 4)
# API keys should never be committed to version control
# Each provider has its own environment variable
# if config_env() == :prod do
#   # Production: API keys are required (except Ollama which is local)
#   config :ragex, :ai_keys,
#     openai: System.fetch_env!("OPENAI_API_KEY"),
#     anthropic: System.fetch_env!("ANTHROPIC_API_KEY"),
#     deepseek: System.fetch_env!("DEEPSEEK_API_KEY")
# else
# Dev/test: use env vars or default to test keys
config :ragex, :ai_keys,
  openai: System.get_env("OPENAI_API_KEY", "test-key"),
  anthropic: System.get_env("ANTHROPIC_API_KEY", "test-key"),
  deepseek: System.get_env("DEEPSEEK_API_KEY", "test-key")

# end
