defmodule Ragex.MCP.Handlers.ToolsTest do
  use ExUnit.Case

  alias Ragex.Graph.Store
  alias Ragex.MCP.Handlers.Tools

  setup do
    # Clear the graph before each test
    Store.clear()
    Store.sync()
    :ok
  end

  describe "list_nodes tool" do
    test "returns the correct total_count when a node_type is provided" do
      # Add various nodes
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.add_node(:module, ModuleC, %{name: ModuleC})
      Store.add_node(:function, {ModuleA, :func1, 0}, %{name: :func1})
      Store.add_node(:function, {ModuleA, :func2, 1}, %{name: :func2})
      Store.sync()

      # Query for modules
      params = %{"node_type" => "module", "limit" => 100}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      assert result.total_count == 3
      assert result.count == 3
    end

    test "returns the correct total_count when no node_type is provided" do
      # Add various nodes
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.add_node(:function, {ModuleA, :func1, 0}, %{name: :func1})
      Store.add_node(:function, {ModuleA, :func2, 1}, %{name: :func2})
      Store.add_node(:function, {ModuleB, :func3, 0}, %{name: :func3})
      Store.sync()

      # Query all nodes
      params = %{"limit" => 100}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      assert result.total_count == 5
      assert result.count == 5
    end

    test "returns a map containing nodes, count, and total_count" do
      # Add some nodes
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:function, {ModuleA, :func1, 0}, %{name: :func1})
      Store.sync()

      params = %{"limit" => 100}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      # Verify map structure
      assert is_map(result)
      assert Map.has_key?(result, :nodes)
      assert Map.has_key?(result, :count)
      assert Map.has_key?(result, :total_count)

      # Verify types
      assert is_list(result.nodes)
      assert is_integer(result.count)
      assert is_integer(result.total_count)
    end

    test "returns correct counts when limit is less than total" do
      # Add more nodes than the limit
      for i <- 1..10 do
        Store.add_node(:module, :"Module#{i}", %{name: :"Module#{i}"})
      end

      Store.sync()
      params = %{"node_type" => "module", "limit" => 5}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      # count should be the actual returned nodes (limited)
      assert result.count == 5
      # total_count should be all matching nodes
      assert result.total_count == 10
    end

    test "handles empty graph correctly" do
      params = %{"limit" => 100}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      assert result.nodes == []
      assert result.count == 0
      assert result.total_count == 0
    end

    test "filters by specific node type correctly" do
      # Add multiple types
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.add_node(:function, {ModuleA, :func1, 0}, %{name: :func1})
      Store.add_node(:function, {ModuleA, :func2, 1}, %{name: :func2})
      Store.add_node(:function, {ModuleA, :func3, 2}, %{name: :func3})
      Store.sync()

      # Query only functions
      params = %{"node_type" => "function", "limit" => 100}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      assert result.count == 3
      assert result.total_count == 3
      # Note: Store.list_nodes returns type as atom, not string
      assert Enum.all?(result.nodes, fn node -> node.type == :function end)
    end
  end

  describe "list_tools/0 — tool description quality" do
    setup do
      %{tools: Tools.list_tools().tools}
    end

    test "every tool has a non-empty description", %{tools: tools} do
      for tool <- tools do
        assert is_binary(tool.description) and String.length(tool.description) > 0,
               "Tool #{tool.name} has missing or empty description"
      end
    end

    test "overlapping search tools have distinct descriptions", %{tools: tools} do
      by_name = Map.new(tools, &{&1.name, &1.description})

      search_tools =
        ~w[semantic_search hybrid_search metaast_search find_similar_code expand_query]

      descriptions =
        search_tools
        |> Enum.filter(&Map.has_key?(by_name, &1))
        |> Enum.map(&Map.fetch!(by_name, &1))

      # No two search tools should have identical descriptions
      assert length(Enum.uniq(descriptions)) == length(descriptions),
             "Duplicate descriptions found among search tools"
    end

    test "search tools mention what makes them distinct", %{tools: tools} do
      by_name = Map.new(tools, &{&1.name, &1.description})

      # hybrid_search should mention it's the best-quality combo
      hybrid_desc = by_name["hybrid_search"]

      assert String.contains?(hybrid_desc, "graph") or String.contains?(hybrid_desc, "fusion"),
             "hybrid_search description should mention graph/fusion"

      # semantic_search should clarify it's embedding-only
      semantic_desc = by_name["semantic_search"]

      assert String.contains?(semantic_desc, "embedding") or
               String.contains?(semantic_desc, "similarity"),
             "semantic_search description should mention embedding/similarity"

      # metaast_search should mention cross-language or structural
      meta_desc = by_name["metaast_search"]

      assert String.contains?(meta_desc, "language") or
               String.contains?(meta_desc, "structural") or
               String.contains?(meta_desc, "MetaAST"),
             "metaast_search description should mention cross-language/structural/MetaAST"
    end

    test "RAG tools guide when to use AI vs raw search", %{tools: tools} do
      by_name = Map.new(tools, &{&1.name, &1.description})

      # rag_query should mention it requires an LLM call or returns answers
      rag_desc = by_name["rag_query"]

      assert String.contains?(rag_desc, "AI") or String.contains?(rag_desc, "answer") or
               String.contains?(rag_desc, "LLM"),
             "rag_query description should mention AI/answer/LLM"

      # stream variants should clarify they are identical output to non-stream
      stream_desc = by_name["rag_query_stream"]

      assert String.contains?(stream_desc, "same") or String.contains?(stream_desc, "identical"),
             "rag_query_stream should clarify it produces the same output as rag_query"
    end

    test "agent tools describe the session workflow", %{tools: tools} do
      by_name = Map.new(tools, &{&1.name, &1.description})

      # agent_analyze should mention it creates a session
      analyze_desc = by_name["agent_analyze"]

      assert String.contains?(analyze_desc, "session"),
             "agent_analyze description should mention session"

      # agent_chat should require a session_id
      chat_desc = by_name["agent_chat"]

      assert String.contains?(chat_desc, "session"),
             "agent_chat description should mention session"
    end

    test "complementary security tools describe their scope differences", %{tools: tools} do
      by_name = Map.new(tools, &{&1.name, &1.description})

      scan_desc = by_name["scan_security"]
      audit_desc = by_name["security_audit"]
      secrets_desc = by_name["check_secrets"]
      issues_desc = by_name["analyze_security_issues"]

      # All four should exist
      assert scan_desc && audit_desc && secrets_desc && issues_desc

      # They should all be distinct
      descs = [scan_desc, audit_desc, secrets_desc, issues_desc]

      assert length(Enum.uniq(descs)) == 4,
             "Security tool descriptions should all be distinct"
    end

    test "pre-requisite tools document their dependencies", %{tools: tools} do
      by_name = Map.new(tools, &{&1.name, &1.description})

      # quality_report needs analyze_quality first
      qr_desc = by_name["quality_report"]

      assert String.contains?(qr_desc, "analyze_quality"),
             "quality_report should mention analyze_quality as a prerequisite"

      # coupling_report needs analyze_dependencies
      cr_desc = by_name["coupling_report"]

      assert String.contains?(cr_desc, "analyze_dependencies"),
             "coupling_report should mention analyze_dependencies as a prerequisite"

      # explain_suggestion needs suggest_refactorings
      es_desc = by_name["explain_suggestion"]

      assert String.contains?(es_desc, "suggest_refactorings"),
             "explain_suggestion should mention suggest_refactorings as a prerequisite"
    end
  end

  describe "tool execution robustness & parameter normalization" do
    test "handles nil arguments gracefully without crashing" do
      assert {:ok, result} = Tools.call_tool("list_nodes", nil)
      assert is_map(result)
      assert Map.has_key?(result, :nodes)
    end

    test "handles non-map arguments safely" do
      assert {:error, error} = Tools.call_tool("read_file", "not_a_map")
      assert error =~ "Tool arguments must be a map"
    end

    test "normalizes atom keys to string keys recursively" do
      # Atom keys for list_nodes
      assert {:ok, result} = Tools.call_tool("list_nodes", %{limit: 10, node_type: "module"})
      assert is_map(result)
    end

    test "read_file tool parses string line numbers" do
      temp_dir = System.tmp_dir!()
      file = Path.join(temp_dir, "read_test_#{:rand.uniform(999_999)}.txt")
      File.write!(file, "line 1\nline 2\nline 3\n")

      on_exit(fn -> File.rm(file) end)

      assert {:ok, result} =
               Tools.call_tool("read_file", %{path: file, start_line: "2", end_line: "3"})

      assert result.range.start == 2
      assert result.range.end == 3
      assert result.content =~ "2|line 2"
    end

    test "returns clear error for unknown tool names" do
      assert {:error, error} = Tools.call_tool("unknown_tool_name_xyz", %{})
      assert error =~ "Unknown tool: unknown_tool_name_xyz"
    end

    test "search and query tools handle missing parameters without crashing" do
      assert {:error, error1} = Tools.call_tool("read_file", %{})
      assert error1 =~ "path"

      assert {:error, error2} = Tools.call_tool("analyze_file", %{})

      assert error2 =~ "path" or error2 =~ "Failed" or error2 =~ "Invalid" or
               error2 =~ "parameters"

      assert {:error, error3} = Tools.call_tool("semantic_search", %{})
      assert error3 =~ "query" or error3 =~ "Missing" or error3 =~ "failed"
    end
  end
end
