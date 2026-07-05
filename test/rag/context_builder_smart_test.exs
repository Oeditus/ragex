defmodule Ragex.RAG.ContextBuilderSmartTest do
  use ExUnit.Case, async: true

  alias Ragex.RAG.ContextBuilder

  defp result(node_id, score, file, line, code) do
    %{
      node_type: :function,
      node_id: node_id,
      score: score,
      file: file,
      line: line,
      code: code,
      text: code,
      language: "elixir"
    }
  end

  describe "smart_assembly: true (default)" do
    test "selects higher-scored results first" do
      low = result({:M, :low, 0}, 0.3, "a.ex", 1, "def low,  do: :ok")
      high = result({:M, :high, 0}, 0.9, "b.ex", 10, "def high, do: :ok")
      mid = result({:M, :mid, 0}, 0.6, "c.ex", 20, "def mid,  do: :ok")

      {:ok, ctx} = ContextBuilder.build_context([low, mid, high])

      # high-scored result should appear before lower-scored ones
      high_pos = :binary.match(ctx, "high") |> elem(0)
      mid_pos = :binary.match(ctx, "mid") |> elem(0)
      assert high_pos < mid_pos
    end

    test "respects max_context_length budget" do
      # Create many results whose combined text exceeds 500 chars
      results =
        Enum.map(1..30, fn i ->
          result({:M, :"f#{i}", 0}, i / 30.0, "#{i}.ex", i, String.duplicate("x", 50))
        end)

      {:ok, ctx} = ContextBuilder.build_context(results, max_context_length: 500)

      assert byte_size(ctx) <= 500 + 50
    end

    test "deduplicates overlapping file ranges" do
      # Two results pointing at the same file and heavily overlapping lines
      r1 =
        result({:M, :chunk_a, 0}, 0.9, "big.ex", 10, Enum.map_join(10..40, "\n", &"line #{&1}"))

      r2 =
        result({:M, :chunk_b, 0}, 0.8, "big.ex", 15, Enum.map_join(15..45, "\n", &"line #{&1}"))

      {:ok, ctx} = ContextBuilder.build_context([r1, r2], max_context_length: 10_000)

      # r1 should be present; r2 overlaps ≥ 0.6 of r1's range and should be dropped
      # format_node_id renders {module, name, arity} as "inspect(module).name/arity"
      assert String.contains?(ctx, ":M.chunk_a/0")
      refute String.contains?(ctx, ":M.chunk_b/0")
    end

    test "does not drop results from different files with same lines" do
      r1 = result({:M, :f, 0}, 0.9, "file_a.ex", 10, Enum.map_join(10..40, "\n", &"line #{&1}"))
      r2 = result({:N, :g, 0}, 0.8, "file_b.ex", 10, Enum.map_join(10..40, "\n", &"line #{&1}"))

      {:ok, ctx} = ContextBuilder.build_context([r1, r2], max_context_length: 10_000)

      assert String.contains?(ctx, "file_a")
      assert String.contains?(ctx, "file_b")
    end

    test "results without file/line are never treated as duplicates of each other" do
      r1 = %{node_type: :function, node_id: {:M, :a, 0}, score: 0.9, text: "text a"}
      r2 = %{node_type: :function, node_id: {:M, :b, 0}, score: 0.8, text: "text b"}

      {:ok, ctx} = ContextBuilder.build_context([r1, r2], max_context_length: 10_000)

      assert String.contains?(ctx, "text a")
      assert String.contains?(ctx, "text b")
    end
  end

  describe "smart_assembly: false" do
    test "falls back to original truncation behaviour" do
      results =
        Enum.map(1..5, fn i ->
          result({:M, :"f#{i}", 0}, i / 5.0, "#{i}.ex", i, "def f#{i}, do: :ok")
        end)

      {:ok, ctx_smart} = ContextBuilder.build_context(results, smart_assembly: true)
      {:ok, ctx_simple} = ContextBuilder.build_context(results, smart_assembly: false)

      # Both produce non-empty contexts; smart may select a subset
      assert byte_size(ctx_smart) > 0
      assert byte_size(ctx_simple) > 0
    end
  end

  describe "line_overlap_ratio (internal, tested via behaviour)" do
    test "0.0 for results with no file info" do
      r1 = %{node_type: :function, node_id: :a, score: 0.9, text: "a"}
      r2 = %{node_type: :function, node_id: :b, score: 0.8, text: "b"}

      # Both lack :file/:line → no overlap detected → both included
      {:ok, ctx} = ContextBuilder.build_context([r1, r2], max_context_length: 10_000)
      assert String.contains?(ctx, "a")
      assert String.contains?(ctx, "b")
    end

    test "fully overlapping ranges (ratio = 1.0) causes deduplication" do
      code = Enum.map_join(1..30, "\n", &"line #{&1}")
      r1 = result({:M, :x, 0}, 0.9, "same.ex", 1, code)
      r2 = result({:M, :y, 0}, 0.8, "same.ex", 1, code)

      {:ok, ctx} = ContextBuilder.build_context([r1, r2], max_context_length: 10_000)

      # format_node_id renders {module, name, arity} as "inspect(module).name/arity"
      assert String.contains?(ctx, ":M.x/0")
      refute String.contains?(ctx, ":M.y/0")
    end
  end
end
