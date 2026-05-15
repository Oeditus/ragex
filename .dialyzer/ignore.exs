# Dialyzer warnings to ignore.
#
# OTP 29 + Elixir 1.20: Dialyzer cannot infer types through rescue blocks for
# :json.decode/1 -- callers of Protocol.decode/1 see only {:error, _}.
# MapSet opaqueness: OTP 29 :sets internal representation triggers
# call_without_opaque false positives.

[
  # --- OTP 29 :json.decode rescue inference cascade ---
  ~r/lib\/ragex\/mcp\/server\.ex/,
  ~r/lib\/ragex\/mcp\/socket_server\.ex/,
  ~r/lib\/ragex\/mcp\/debug\.ex/,
  ~r/lib\/ragex\/mcp\/single_request\.ex/,

  # --- Core.analyze_project cascade ---
  ~r/lib\/mix\/tasks\/ragex\.audit\.ex/,
  ~r/lib\/mix\/tasks\/ragex\.cache\.refresh\.ex/,
  ~r/lib\/ragex\/cli\/chat\.ex:328/,
  ~r/lib\/ragex\/cli\/chat\.ex.*(unused_fun|pattern_match)/,
  ~r/lib\/ragex\/mcp\/handlers\/tools\.ex/,

  # --- refactor.ex Prompt.select cascade ---
  ~r/lib\/mix\/tasks\/ragex\.refactor\.ex/,

  # --- Remaining guard_fail on non-nilable types (|| "" / || [] patterns) ---
  ~r/duplication\.ex.*guard_fail/,
  ~r/metastatic_bridge\.ex.*guard_fail/,
  ~r/suggestions\.ex.*guard_fail/,
  ~r/tools\.ex.*(guard_fail|6711|6718)/,

  # --- Application.compile_env false positive (OTP 29) ---
  ~r/:1:pattern_match.*true/,

  # --- tools.ex remaining cascading from modify_attributes/change_signature ---
  ~r/tools\.ex:(3830|3865|3933|2762|6263)/,

  # --- Remaining pattern_match in refactor/elixir.ex parse_code ---
  ~r/refactor\/elixir\.ex:104.*pattern_match_cov/,

  # --- elixir analyzer :after pattern (only :before is called) ---
  # ~r/analyzers\/elixir\.ex:606.*pattern_match/,

  # --- MapSet opaqueness (OTP 29 :sets internal representation) ---
  ~r/call_without_opaque/
]
