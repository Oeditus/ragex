import Config

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

# Editor Configuration (Phase 5)
config :ragex, :editor,
  backup_dir: Path.expand("~/.ragex/backups"),
  backup_retention: 10,
  validate_by_default: true,
  create_backup_by_default: true,
  compress_backups: false,
  # 10MB
  max_file_size: 10_485_760

# Import environment-specific config
if config_env() == :test do
  import_config "test.exs"
end
