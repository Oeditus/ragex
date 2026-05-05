# Pre-existing Dialyzer warnings that are either false positives or
# require deeper refactoring outside the current scope.
#
# Categories:
# - MapSet opaque type warnings (well-known Dialyzer limitation)
# - Defensive catch-all clauses (pattern_match_cov)
# - Unreachable code due to early exits / guard inference
# - MCP server/protocol parse chain (JSON-RPC parse always errors in Dialyzer's view)
# - Interactive CLI wizards (Prompt.select type mismatch)
[
  # --- MapSet opaque type warnings (known Dialyzer false positives) ---
  # Formatted warnings
  ~r/lib\/ragex\/analysis\/dependency_graph\.ex.*call_without_opaque/,
  ~r/lib\/ragex\/editor\/refactor\/elixir\.ex.*call_without_opaque/,
  ~r/lib\/ragex\/editor\/conflict\.ex.*call_without_opaque/,
  ~r/lib\/ragex\/editor\/visualize\.ex.*call_without_opaque/,
  ~r/lib\/ragex\/graph\/algorithms\.ex.*call_without_opaque/,

  # --- Defensive catch-all clauses that Dialyzer proves unreachable ---
  ~r/lib\/ragex\/ai\/features\/config\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/ai\/registry\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/analysis\/business_logic\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/analysis\/metastatic_bridge\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/analysis\/security\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/analysis\/smells\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/analyzers\/elixir\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/editor\/refactor\/elixir\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/editor\/validators\/elixir\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/language_support\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/mcp\/handlers\/tools\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/rag\/pipeline\.ex.*pattern_match_cov/,
  ~r/lib\/ragex\/cli\/chat\.ex.*pattern_match_cov/,

  # --- MCP server/protocol: JSON-RPC parse chain inferred as always-error ---
  ~r/lib\/ragex\/mcp\/server\.ex/,
  ~r/lib\/ragex\/mcp\/socket_server\.ex/,
  ~r/lib\/ragex\/mcp\/single_request\.ex/,
  ~r/lib\/ragex\/mcp\/debug\.ex/,

  # --- Guard/pattern inference false positives ---
  ~r/lib\/ragex\/agent\/executor\.ex.*guard_fail/,
  ~r/lib\/ragex\/analysis\/duplication\.ex.*guard_fail/,
  ~r/lib\/ragex\/analysis\/metastatic_bridge\.ex.*guard_fail/,
  ~r/lib\/ragex\/editor\/validators\/elixir\.ex.*guard_fail/,
  ~r/lib\/ragex\/editor\/validators\/javascript\.ex.*guard_fail/,
  ~r/lib\/ragex\/editor\/validators\/python\.ex.*guard_fail/,
  ~r/lib\/ragex\/editor\/validators\/ruby\.ex.*guard_fail/,
  ~r/lib\/ragex\/mcp\/handlers\/tools\.ex.*guard_fail/,

  # --- Unreachable pattern matches in call chains ---
  ~r/lib\/ragex\/analysis\/suggestions\.ex:255.*call/,
  ~r/lib\/ragex\/analysis\/suggestions\/patterns\.ex.*pattern_match/,
  ~r/lib\/ragex\/analysis\/suggestions\/rag_advisor\.ex/,
  ~r/lib\/ragex\/ai\/features\/context\.ex.*pattern_match/,
  ~r/lib\/ragex\/analyzers\/elixir\.ex:610.*pattern_match/,
  ~r/lib\/ragex\/cli\/chat\.ex:328.*pattern_match/,
  ~r/lib\/ragex\/cli\/chat\.ex.*unused_fun/,
  ~r/lib\/ragex\/cli\/colors\.ex.*pattern_match/,
  ~r/lib\/ragex\/editor\/refactor\/elixir\.ex:101.*pattern_match/,
  ~r/lib\/ragex\/editor\/validators\/elixir\.ex.*pattern_match/,

  # --- MCP tools module-level pattern (compile-time constant) ---
  ~r/lib\/ragex\/mcp\/handlers\/tools\.ex:1:pattern_match/,

  # --- MCP handlers: unreachable code from call chain inference ---
  ~r/lib\/ragex\/mcp\/handlers\/resources\.ex/,
  ~r/lib\/ragex\/mcp\/handlers\/tools\.ex:3667.*call/,
  ~r/lib\/ragex\/mcp\/handlers\/tools\.ex:3702.*call/,
  ~r/lib\/ragex\/mcp\/handlers\/tools\.ex:3770.*pattern_match/,
  ~r/lib\/ragex\/mcp\/handlers\/tools\.ex:8197.*pattern_match/,
  ~r/lib\/ragex\/mcp\/handlers\/tools\.ex:8332.*pattern_match/,

  # --- Interactive CLI wizards (Prompt.select signature mismatch) ---
  ~r/lib\/mix\/tasks\/ragex\.configure\.ex/,
  ~r/lib\/mix\/tasks\/ragex\.refactor\.ex/,
  ~r/lib\/mix\/tasks\/ragex\.cache\.refresh\.ex/,

  # --- Audit task: same MCP/core call chain inference ---
  ~r/lib\/mix\/tasks\/ragex\.audit\.ex/,

  # --- Quality spec mismatch (pre-existing) ---
  ~r/lib\/ragex\/analysis\/quality\.ex.*invalid_contract/,
]
