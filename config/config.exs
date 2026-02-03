import Config

# Logger Configuration  
# MCP protocol uses stdout for JSON-RPC, so logs MUST go to stderr
# Using OTP logger (Elixir 1.15+)
config :logger,
  level: "LOG_LEVEL" |> System.get_env("info") |> String.to_existing_atom(),
  handle_otp_reports: true,
  handle_sasl_reports: true,
  default_handler: [
    # config: [type: :standard_error]
    config: [
      file: ~c"ragex.log",
      filesync_repeat_interval: 5000,
      file_check: 5000,
      max_no_bytes: 10_000_000,
      max_no_files: 5,
      compress_on_rotate: true
    ]
  ]

# Bumblebee Configuration
# Disable progress bars to avoid ANSI escape sequences in MCP stdio output
config :bumblebee, :progress_bar_enabled, false

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

# AI Provider Configuration (Phase 4)
# Multi-provider support with fallback
config :ragex, :ai,
  providers: [:openai, :anthropic, :deepseek_r1, :ollama],
  default_provider: :openai,
  fallback_enabled: true

# Provider-specific configurations
config :ragex, :ai_providers,
  openai: [
    endpoint: "https://api.openai.com/v1",
    model: "gpt-4-turbo",
    options: [
      temperature: 0.7,
      max_tokens: 2048,
      stream: false
    ]
  ],
  anthropic: [
    endpoint: "https://api.anthropic.com/v1",
    model: "claude-3-sonnet-20240229",
    options: [
      temperature: 0.7,
      max_tokens: 2048
    ]
  ],
  deepseek_r1: [
    endpoint: "https://api.deepseek.com",
    model: "deepseek-chat",
    options: [
      temperature: 0.7,
      max_tokens: 2048,
      stream: false
    ]
  ],
  ollama: [
    endpoint: "http://localhost:11434",
    model: "codellama",
    options: [
      temperature: 0.7,
      max_tokens: 2048
    ]
  ]

# AI Cache Configuration (Phase 4B)
config :ragex, :ai_cache,
  enabled: true,
  ttl: 3600,
  max_size: 1000,
  operation_caches: %{
    query: %{ttl: 3600, max_size: 500},
    explain: %{ttl: 7200, max_size: 300},
    suggest: %{ttl: 1800, max_size: 200}
  }

# Rate Limiting Configuration (Phase 4C)
config :ragex, :ai_limits,
  max_requests_per_minute: 60,
  max_requests_per_hour: 1000,
  max_tokens_per_day: 100_000

# Auto-analyze directories on startup
# Add directories to scan and index automatically when Ragex starts
# Example: ["/opt/Proyectos/MyProject", "/home/user/code"]
config :ragex, :auto_analyze_dirs, []

# Feature Flags
config :ragex, :features,
  use_metastatic: true,
  fallback_to_native_analyzers: true

# Analysis Configuration
config :ragex, :analysis,
  # Enable/disable dead code detection (can be noisy)
  enable_dead_code_detection: true,
  # Minimum confidence for dead code reporting (0.0-1.0)
  dead_code_min_confidence: 0.5

config :bumblebee, :progress_bar_enabled, false

if File.exists?("config/#{Mix.env()}.exs"), do: import_config("#{Mix.env()}.exs")
