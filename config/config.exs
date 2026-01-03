import Config

# Logger Configuration  
# MCP protocol uses stdout for JSON-RPC, so logs MUST go to stderr
# Using OTP logger (Elixir 1.15+)
config :logger,
  level: :info,
  handle_otp_reports: true,
  handle_sasl_reports: true

config :logger, :default_handler,
  config: [
    type: :standard_error
  ]

# Embedding Model Configuration
# Choose from: :all_minilm_l6_v2 (default), :all_mpnet_base_v2, :codebert_base, :paraphrase_multilingual
#
# You can also set via environment variable:
#   export RAGEX_EMBEDDING_MODEL=codebert_base
#
# Model comparison:
# - all_minilm_l6_v2: Fast, 384 dims, good for small-medium codebases
# - all_mpnet_base_v2: High quality, 768 dims, best for large codebases
# - codebert_base: Code-specific, 768 dims, optimized for programming
# - paraphrase_multilingual: Multilingual, 384 dims, 50+ languages

config :ragex,
       :embedding_model,
       System.get_env("RAGEX_EMBEDDING_MODEL", "all_minilm_l6_v2") |> String.to_atom()

# Cache Configuration
config :ragex, :cache,
  enabled: true,
  dir: Path.expand("~/.cache/ragex"),
  max_age_days: 30

config :ragex, :timeouts,
  bumblebee: :infinity,
  store: :infinity,
  watcher: :infinity

# Editor Configuration (Phase 5)
config :ragex, :editor,
  backup_dir: Path.expand("~/.ragex/backups"),
  backup_retention: 10,
  validate_by_default: true,
  create_backup_by_default: true,
  compress_backups: false,
  # 10MB
  max_file_size: 10_485_760

# Graph Algorithms Configuration (Phase 8)
config :ragex, :graph,
  # Maximum nodes to compute for betweenness centrality
  max_nodes_betweenness: 10_000,
  # Maximum nodes to export in visualization formats
  max_nodes_export: 10_000

# Semantic Search Configuration
config :ragex, :search,
  # Default similarity threshold (0.0-1.0)
  # Lower values = more results but lower quality
  # Typical useful range: 0.1-0.3 for all-MiniLM-L6-v2
  default_threshold: 0.2,
  # Lower threshold for hybrid search (more recall)
  hybrid_threshold: 0.15

if File.exists?("config/#{Mix.env()}.exs"), do: import_config("#{Mix.env()}.exs")
