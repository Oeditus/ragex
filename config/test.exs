import Config

# Use default model for tests (fastest)
config :ragex, :embedding_model, :all_minilm_l6_v2

# Disable cache for tests (for isolation)
config :ragex, :cache,
  enabled: false,
  dir: Path.expand("~/.cache/ragex/test")

config :ragex, :features,
  suggestions: true,
  dead_code: true
