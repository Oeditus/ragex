defmodule Ragex.MCP.FormatterTest do
  @moduledoc """
  Tests for the context compaction system (Phase F).

  Covers the Formattable protocol, Formatter module, token budget,
  and smart suggestions.
  """

  use ExUnit.Case, async: true

  alias Ragex.MCP.{Formattable, Formatter}

  # ── Formattable protocol: Map ────────────────────────────────────────

  describe "Formattable.compact/2 for Map" do
    test "passes through small maps unchanged" do
      input = %{status: "success", count: 3}
      assert Formattable.compact(input, []) == input
    end

    test "truncates long lists in known keys" do
      items = Enum.map(1..25, fn i -> %{id: i, name: "item_#{i}"} end)
      input = %{results: items, count: 25}

      compacted = Formattable.compact(input, max_items: 5)

      assert length(compacted.results) == 5
      assert compacted.truncated == %{results: 20}
    end

    test "strips verbose string fields over 200 chars" do
      long_text = String.duplicate("a", 300)
      input = %{message: long_text, status: "ok"}

      compacted = Formattable.compact(input, [])

      assert String.length(compacted.message) < 300
      assert String.ends_with?(compacted.message, "...")
    end

    test "preserves short string fields" do
      input = %{message: "short", status: "ok"}
      assert Formattable.compact(input, []) == input
    end

    test "strips doc/moduledoc/specs from nested items" do
      items = [
        %{name: "foo", doc: "Long documentation here", specs: "@spec foo() :: :ok"}
      ]

      input = %{results: items}
      compacted = Formattable.compact(input, [])

      first = hd(compacted.results)
      refute Map.has_key?(first, :doc)
      refute Map.has_key?(first, :specs)
      assert first.name == "foo"
    end
  end

  # ── Formattable protocol: List ───────────────────────────────────────

  describe "Formattable.compact/2 for List" do
    test "passes through short lists" do
      assert Formattable.compact([1, 2, 3], []) == [1, 2, 3]
    end

    test "wraps long lists in a truncation envelope" do
      list = Enum.to_list(1..50)
      result = Formattable.compact(list, max_items: 5)

      assert result.total == 50
      assert result.truncated == 45
      assert [_, _, _, _, _] = result.items
    end
  end

  # ── Formattable protocol: scalars ────────────────────────────────────

  describe "Formattable.compact/2 for scalars" do
    test "passes through strings" do
      assert Formattable.compact("hello", []) == "hello"
    end

    test "passes through atoms" do
      assert Formattable.compact(:ok, []) == :ok
    end

    test "passes through integers" do
      assert Formattable.compact(42, []) == 42
    end

    test "passes through floats" do
      assert Formattable.compact(3.14, []) == 3.14
    end
  end

  # ── Formatter.format/3 ──────────────────────────────────────────────

  describe "Formatter.format/3" do
    test "verbose mode passes result through unchanged" do
      input = %{results: Enum.to_list(1..50), count: 50}
      result = Formatter.format(input, "semantic_search", verbose: true)
      assert result == input
    end

    test "compact mode truncates and adds suggestions" do
      items = Enum.map(1..25, fn i -> %{node_id: "Mod.func/#{i}", score: 0.9} end)
      input = %{results: items, count: 25, query: "test"}

      result = Formatter.format(input, "semantic_search")

      # Should be truncated
      assert length(result.results) == 10
      # Should have truncation metadata
      assert result.truncated == %{results: 15}
      # Should have suggestions
      assert is_list(result._suggestions)
    end

    test "compact mode does not modify small results" do
      input = %{status: "success", count: 2}
      result = Formatter.format(input, "some_tool")

      assert result.status == "success"
      assert result.count == 2
    end
  end

  # ── Formatter.extract_opts/1 ────────────────────────────────────────

  describe "Formatter.extract_opts/1" do
    test "extracts verbose from arguments" do
      assert Formatter.extract_opts(%{"verbose" => true}) == [verbose: true]
    end

    test "extracts max_tokens from arguments" do
      assert Formatter.extract_opts(%{"max_tokens" => 500}) == [max_tokens: 500]
    end

    test "extracts both" do
      opts = Formatter.extract_opts(%{"verbose" => true, "max_tokens" => 1000})
      assert Keyword.get(opts, :verbose) == true
      assert Keyword.get(opts, :max_tokens) == 1000
    end

    test "returns empty list for no formatting args" do
      assert Formatter.extract_opts(%{"path" => "/foo"}) == []
    end

    test "ignores invalid max_tokens" do
      assert Formatter.extract_opts(%{"max_tokens" => -1}) == []
      assert Formatter.extract_opts(%{"max_tokens" => "abc"}) == []
    end

    test "handles non-map input" do
      assert Formatter.extract_opts(nil) == []
      assert Formatter.extract_opts("string") == []
    end
  end

  # ── Token budget ────────────────────────────────────────────────────

  describe "token budget" do
    test "estimate_tokens returns reasonable values" do
      small = %{status: "ok"}
      large = %{results: Enum.map(1..100, fn i -> %{id: i, name: String.duplicate("x", 50)} end)}

      small_tokens = Formatter.estimate_tokens(small)
      large_tokens = Formatter.estimate_tokens(large)

      assert small_tokens < 20
      assert large_tokens > 500
    end

    test "max_tokens causes progressive truncation" do
      items = Enum.map(1..100, fn i -> %{id: i, data: String.duplicate("x", 100)} end)
      input = %{results: items, count: 100}

      # Very tight budget should produce much smaller output
      result = Formatter.format(input, "test", max_tokens: 50)
      result_tokens = Formatter.estimate_tokens(result)

      # Should be significantly smaller than original
      original_tokens = Formatter.estimate_tokens(input)
      assert result_tokens < original_tokens
    end
  end

  # ── Smart suggestions ───────────────────────────────────────────────

  describe "suggest_next/2" do
    test "adds truncation hint when results are truncated" do
      result = %{truncated: %{results: 15}}
      suggestions = Formatter.suggest_next(result, "semantic_search")

      assert Enum.any?(suggestions, &String.contains?(&1, "verbose=true"))
    end

    test "suggests find_callers after semantic_search" do
      result = %{results: [%{node_id: "MyMod.func/2"}]}
      suggestions = Formatter.suggest_next(result, "semantic_search")

      assert Enum.any?(suggestions, &String.contains?(&1, "find_callers"))
    end

    test "suggests analyze_impact after find_callers" do
      suggestions = Formatter.suggest_next(%{target: "Mod.func/2"}, "find_callers")
      assert Enum.any?(suggestions, &String.contains?(&1, "analyze_impact"))
    end

    test "suggests git_blame after query_graph find" do
      result = %{found: true, node: %{file: "lib/user.ex"}}
      suggestions = Formatter.suggest_next(result, "query_graph")
      assert Enum.any?(suggestions, &String.contains?(&1, "git_blame"))
    end

    test "suggests git_history after git_blame" do
      suggestions = Formatter.suggest_next(%{file: "lib/user.ex"}, "git_blame")
      assert Enum.any?(suggestions, &String.contains?(&1, "git_history"))
    end

    test "suggests betweenness_centrality after graph_stats" do
      suggestions = Formatter.suggest_next(%{}, "graph_stats")
      assert Enum.any?(suggestions, &String.contains?(&1, "betweenness_centrality"))
    end

    test "returns empty list for unknown tools" do
      assert Formatter.suggest_next(%{}, "unknown_tool") == []
    end

    test "suggests limit increase for list_nodes" do
      result = %{count: 10, total_count: 500}
      suggestions = Formatter.suggest_next(result, "list_nodes")
      assert Enum.any?(suggestions, &String.contains?(&1, "500"))
    end
  end
end
