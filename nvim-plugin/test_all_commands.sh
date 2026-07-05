#!/usr/bin/env bash
# Test all Ragex MCP commands via direct socat calls
# This validates that the plugin commands map correctly to MCP tools

# Don't exit on errors - we want to test all commands
set +e

SOCKET="/tmp/ragex_mcp.sock"
TEST_DIR="/opt/Proyectos/Oeditus/ragex"
TEST_FILE="$TEST_DIR/lib/ragex/graph/store.ex"
FAILED=0
PASSED=0

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Testing Ragex MCP Commands"
echo "Socket: $SOCKET"
echo "Test directory: $TEST_DIR"
echo "=========================================="
echo ""

# Helper function to test a command
test_command() {
  local name="$1"
  local tool="$2"
  local params="$3"
  
  echo -n "Testing $name... "
  
  local request=$(cat <<EOF
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"$tool","arguments":$params},"id":1}
EOF
)
  
  local response=$(printf '%s\n' "$request" | timeout 15 socat -t12 - UNIX-CONNECT:$SOCKET 2>&1)
  
  if echo "$response" | grep -q '"result"'; then
    echo -e "${GREEN}✓ PASS${NC}"
    ((PASSED++))
    return 0
  elif echo "$response" | grep -q '"error"'; then
    local error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1)
    echo -e "${YELLOW}⚠ ERROR${NC}: $error_msg"
    ((FAILED++))
    return 1
  else
    echo -e "${RED}✗ FAIL${NC}: No response or timeout"
    echo "Request: $request"
    echo "Response: $response"
    ((FAILED++))
    return 1
  fi
}

echo "=== BASIC COMMANDS ==="
echo ""

# 1. graph_stats (no params required)
test_command "graph_stats" "graph_stats" "{}"

# 2. analyze_file
test_command "analyze_file" "analyze_file" "{\"path\":\"$TEST_FILE\"}"

# 3. semantic_search
test_command "semantic_search" "semantic_search" "{\"query\":\"function to add node\",\"limit\":5}"

# 4. hybrid_search
test_command "hybrid_search" "hybrid_search" "{\"query\":\"graph algorithms\",\"limit\":5}"

# 5. list_nodes
test_command "list_nodes" "list_nodes" "{\"limit\":10}"

# 6. get_embeddings_stats
test_command "get_embeddings_stats" "get_embeddings_stats" "{}"

echo ""
echo "=== GRAPH ALGORITHMS ==="
echo ""

# 7. betweenness_centrality
test_command "betweenness_centrality" "betweenness_centrality" "{\"max_nodes\":100}"

# 8. closeness_centrality
test_command "closeness_centrality" "closeness_centrality" "{}"

# 9. detect_communities
test_command "detect_communities" "detect_communities" "{\"algorithm\":\"louvain\"}"

# 10. export_graph
test_command "export_graph" "export_graph" "{\"format\":\"graphviz\",\"max_nodes\":50}"

echo ""
echo "=== CODE QUALITY ==="
echo ""

# 11. analyze_quality
test_command "analyze_quality" "analyze_quality" "{\"path\":\"$TEST_FILE\"}"

# 12. quality_report
test_command "quality_report" "quality_report" "{\"format\":\"json\"}"

# 13. find_complex_code
test_command "find_complex_code" "find_complex_code" "{\"metric\":\"cyclomatic\",\"threshold\":10,\"limit\":5}"

echo ""
echo "=== DEPENDENCIES ==="
echo ""

# 14. analyze_dependencies
test_command "analyze_dependencies" "analyze_dependencies" "{}"

# 15. find_circular_dependencies
test_command "find_circular_dependencies" "find_circular_dependencies" "{}"

# 16. coupling_report
test_command "coupling_report" "coupling_report" "{\"format\":\"json\"}"

echo ""
echo "=== DEAD CODE & DUPLICATES ==="
echo ""

# 17. find_dead_code
test_command "find_dead_code" "find_dead_code" "{\"scope\":\"all\",\"min_confidence\":0.5}"

# 18. analyze_dead_code_patterns
test_command "analyze_dead_code_patterns" "analyze_dead_code_patterns" "{\"path\":\"$TEST_FILE\"}"

# 19. find_duplicates
test_command "find_duplicates" "find_duplicates" "{\"path\":\"$TEST_DIR/lib\",\"threshold\":0.8}"

# 20. find_similar_code
test_command "find_similar_code" "find_similar_code" "{\"threshold\":0.95,\"limit\":10}"

echo ""
echo "=== IMPACT ANALYSIS ==="
echo ""

# 21. analyze_impact
test_command "analyze_impact" "analyze_impact" "{\"target\":\"Ragex.Graph.Store\"}"

# 22. estimate_refactoring_effort
test_command "estimate_refactoring_effort" "estimate_refactoring_effort" "{\"target\":\"Ragex.Graph.Store\",\"operation\":\"rename_module\"}"

# 23. risk_assessment
test_command "risk_assessment" "risk_assessment" "{\"target\":\"Ragex.Graph.Store\"}"

echo ""
echo "=== REFACTORING SUGGESTIONS ==="
echo ""

# 24. suggest_refactorings
test_command "suggest_refactorings" "suggest_refactorings" "{\"target\":\"$TEST_FILE\",\"min_priority\":\"low\"}"

echo ""
echo "=== SEMANTIC & SECURITY (Phase D) ==="
echo ""

# 25. semantic_operations
test_command "semantic_operations" "semantic_operations" "{\"path\":\"$TEST_FILE\"}"

# 26. analyze_security_issues
test_command "analyze_security_issues" "analyze_security_issues" "{\"path\":\"$TEST_FILE\"}"

# 27. semantic_analysis
test_command "semantic_analysis" "semantic_analysis" "{\"path\":\"$TEST_FILE\"}"

# 28. analyze_business_logic
test_command "analyze_business_logic" "analyze_business_logic" "{\"path\":\"$TEST_FILE\"}"

echo ""
echo "=== SECURITY ==="
echo ""

# 29. scan_security
test_command "scan_security" "scan_security" "{\"path\":\"$TEST_FILE\"}"

# 30. check_secrets
test_command "check_secrets" "check_secrets" "{\"path\":\"$TEST_FILE\"}"

# 31. detect_smells
test_command "detect_smells" "detect_smells" "{\"path\":\"$TEST_FILE\"}"

echo ""
echo "=== RAG FEATURES ==="
echo ""

# 32. expand_query
test_command "expand_query" "expand_query" "{\"query\":\"function to store graph data\",\"max_terms\":3}"

# 33. metaast_search
test_command "metaast_search" "metaast_search" "{\"source_language\":\"elixir\",\"source_construct\":\"Enum.map/2\",\"limit\":3}"

echo ""
echo "=== AI CACHE ==="
echo ""

# 34. get_ai_cache_stats
test_command "get_ai_cache_stats" "get_ai_cache_stats" "{}"

# 35. get_ai_usage
test_command "get_ai_usage" "get_ai_usage" "{}"

# 36. clear_ai_cache (skip - destructive)
echo "Skipping clear_ai_cache (destructive operation)"

echo ""
echo "=== PREVIEW & CONFLICTS ==="
echo ""

# 37. refactor_conflicts
test_command "refactor_conflicts" "refactor_conflicts" "{\"operation\":\"rename_module\",\"params\":{\"old_name\":\"TestModule\",\"new_name\":\"NewModule\"}}"

# 38. refactor_history
test_command "refactor_history" "refactor_history" "{\"limit\":5}"

echo ""
echo "=== CROSS-LANGUAGE ==="
echo ""

# 39. cross_language_alternatives
test_command "cross_language_alternatives" "cross_language_alternatives" "{\"language\":\"elixir\",\"code\":\"Enum.map(list, fn x -> x * 2 end)\"}"

# 40. find_metaast_pattern
test_command "find_metaast_pattern" "find_metaast_pattern" "{\"pattern\":\"collection_op:map\",\"limit\":5}"

echo ""
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${YELLOW}Some tests failed. Review output above.${NC}"
  exit 1
fi
