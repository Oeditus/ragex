import Config

# Use the in-memory ETS store backend for tests instead of the :dllb default
# (config/config.exs). Unit tests use plain, symbolic atoms as node/module
# identifiers (e.g. `:ModA`, `:Lib`) that are not real `Elixir.*` module
# references. The dllb backend's node-identity encoding round-trips those
# through `inspect/1` / `Atom.to_string/1` and assumes real module aliases,
# so it cannot losslessly reconstruct plain atoms -- this breaks
# `Store.list_modules/0`, `Store.list_functions/1` (module filter), and
# every analysis module built on them. It would also spawn real OS
# `dllb-server` processes and persist to disk during the test run. ETS
# stores raw terms directly (no encoding), so identifiers always round-trip
# exactly, and `Store.clear/0` (`:ets.delete_all_objects/1`) fully resets
# state between tests without touching the filesystem.
config :ragex, :store_backend, :ets

# Use default model for tests (fastest)
config :ragex, :embedding_model, :all_minilm_l6_v2

# Disable cache for tests (for isolation)
config :ragex, :cache,
  enabled: false,
  dir: Path.expand("~/.cache/ragex/test")

config :ragex, :features,
  suggestions: true,
  dead_code: true
