defmodule Ragex.VectorStoreTest do
  use ExUnit.Case, async: false

  alias Ragex.Embeddings.Bumblebee
  alias Ragex.Graph.Store
  alias Ragex.VectorStore

  @moduletag :embeddings
  @moduletag timeout: 120_000

  setup do
    # Clear store before each test
    Store.clear()
    wait_for_ready()
    :ok
  end

  describe "cosine_similarity/2" do
    test "returns 1.0 for identical vectors" do
      vec = [1.0, 2.0, 3.0]
      assert VectorStore.cosine_similarity(vec, vec) == 1.0
    end

    test "returns 0.0 for orthogonal vectors" do
      vec1 = [1.0, 0.0, 0.0]
      vec2 = [0.0, 1.0, 0.0]

      similarity = VectorStore.cosine_similarity(vec1, vec2)
      assert_in_delta similarity, 0.0, 0.0001
    end

    test "returns -1.0 for opposite vectors" do
      vec1 = [1.0, 2.0, 3.0]
      vec2 = [-1.0, -2.0, -3.0]

      similarity = VectorStore.cosine_similarity(vec1, vec2)
      assert_in_delta similarity, -1.0, 0.0001
    end

    test "handles zero vectors" do
      vec1 = [0.0, 0.0, 0.0]
      vec2 = [1.0, 2.0, 3.0]

      assert VectorStore.cosine_similarity(vec1, vec2) == 0.0
    end

    test "calculates similarity for normalized vectors" do
      # These are normalized (unit length)
      vec1 = [0.6, 0.8, 0.0]
      vec2 = [0.8, 0.6, 0.0]

      similarity = VectorStore.cosine_similarity(vec1, vec2)
      assert similarity > 0.9
      assert similarity < 1.0
    end
  end

  describe "search/2" do
    test "finds similar embeddings by semantic meaning" do
      # Store some test embeddings
      {:ok, emb1} = Bumblebee.embed("Calculate the sum of two numbers")
      {:ok, emb2} = Bumblebee.embed("Add two integers together")
      {:ok, emb3} = Bumblebee.embed("Parse JSON from a string")

      Store.store_embedding(:function, {:Math, :sum, 2}, emb1, "sum function")
      Store.store_embedding(:function, {:Math, :add, 2}, emb2, "add function")
      Store.store_embedding(:function, {:Parser, :parse_json, 1}, emb3, "parse function")

      # Search for similar to "add numbers"
      {:ok, query_emb} = Bumblebee.embed("add numbers")
      results = VectorStore.search(query_emb, limit: 3, threshold: 0.0)

      # Should get at least 2 results (semantic similarity can vary)
      assert length(results) >= 2
      assert length(results) <= 3

      # First two results should be math-related with higher scores
      [first, second | rest] = results

      # Math-related functions should have decent similarity (but not too strict)
      assert first.score > 0.5
      assert second.score > 0.5
      # If there's a third result (JSON parsing), it should be less similar
      if rest != [] do
        third = hd(rest)
        assert third.score < first.score
      end

      # Verify structure
      assert first.node_type == :function
      assert is_tuple(first.node_id)
      assert is_float(first.score)
      assert is_binary(first.text)
      assert is_list(first.embedding)
    end

    test "respects limit parameter" do
      # Store 5 embeddings
      for i <- 1..5 do
        {:ok, emb} = Bumblebee.embed("test function #{i}")
        Store.store_embedding(:function, {:Mod, String.to_atom("func#{i}"), 0}, emb, "test")
      end

      {:ok, query_emb} = Bumblebee.embed("test function")

      results = VectorStore.search(query_emb, limit: 3)
      assert length(results) == 3

      results = VectorStore.search(query_emb, limit: 10)
      # Only 5 exist
      assert length(results) == 5
    end

    test "filters by similarity threshold" do
      {:ok, emb1} = Bumblebee.embed("very similar text")
      {:ok, emb2} = Bumblebee.embed("completely different unrelated content")

      Store.store_embedding(:function, {:A, :a, 0}, emb1, "text1")
      Store.store_embedding(:function, {:B, :b, 0}, emb2, "text2")

      {:ok, query_emb} = Bumblebee.embed("very similar text")

      # With high threshold, should only get exact match
      results = VectorStore.search(query_emb, threshold: 0.95)
      assert length(results) == 1
      assert results |> hd() |> Map.get(:score) > 0.95

      # With low threshold, should get both
      results = VectorStore.search(query_emb, threshold: 0.0)
      assert length(results) == 2
    end

    test "filters by node type" do
      {:ok, emb1} = Bumblebee.embed("test")
      {:ok, emb2} = Bumblebee.embed("test")

      Store.store_embedding(:module, :ModA, emb1, "module")
      Store.store_embedding(:function, {:ModB, :func, 0}, emb2, "function")

      {:ok, query_emb} = Bumblebee.embed("test")

      # Filter for modules only
      results = VectorStore.search(query_emb, node_type: :module)
      assert length(results) == 1
      assert hd(results).node_type == :module

      # Filter for functions only
      results = VectorStore.search(query_emb, node_type: :function)
      assert length(results) == 1
      assert hd(results).node_type == :function
    end

    test "returns empty list when no embeddings exist" do
      {:ok, query_emb} = Bumblebee.embed("test")
      results = VectorStore.search(query_emb)

      assert results == []
    end

    test "returns results sorted by similarity descending" do
      {:ok, emb1} = Bumblebee.embed("exact match text")
      {:ok, emb2} = Bumblebee.embed("similar but not exact")
      {:ok, emb3} = Bumblebee.embed("very different content")

      Store.store_embedding(:function, {:A, :a, 0}, emb1, "text1")
      Store.store_embedding(:function, {:B, :b, 0}, emb2, "text2")
      Store.store_embedding(:function, {:C, :c, 0}, emb3, "text3")

      {:ok, query_emb} = Bumblebee.embed("exact match text")
      results = VectorStore.search(query_emb)

      # Verify descending order
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)

      # First result should have highest score
      assert hd(results).score > 0.95
    end
  end

  describe "nearest_neighbors/3" do
    test "returns k nearest neighbors" do
      # Store multiple embeddings
      for i <- 1..10 do
        {:ok, emb} = Bumblebee.embed("function number #{i}")
        Store.store_embedding(:function, {:Mod, String.to_atom("f#{i}"), 0}, emb, "test")
      end

      {:ok, query_emb} = Bumblebee.embed("function number 5")

      results = VectorStore.nearest_neighbors(query_emb, 5)
      assert length(results) == 5

      # Results should be sorted by similarity
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  describe "stats/0" do
    test "returns statistics about stored embeddings" do
      stats = VectorStore.stats()

      assert Map.has_key?(stats, :total_embeddings)
      assert Map.has_key?(stats, :dimensions)
      assert stats.total_embeddings == 0
    end

    test "counts embeddings correctly" do
      {:ok, emb1} = Bumblebee.embed("test 1")
      {:ok, emb2} = Bumblebee.embed("test 2")

      Store.store_embedding(:function, {:A, :a, 0}, emb1, "text")
      Store.store_embedding(:module, :B, emb2, "text")

      stats = VectorStore.stats()
      assert stats.total_embeddings == 2
      assert stats.dimensions == 384
    end
  end

  describe "performance" do
    @tag :slow
    test "handles large number of embeddings efficiently" do
      # Store 100 embeddings
      for i <- 1..100 do
        {:ok, emb} = Bumblebee.embed("function #{i}")
        Store.store_embedding(:function, {:Mod, String.to_atom("f#{i}"), 0}, emb, "test")
      end

      {:ok, query_emb} = Bumblebee.embed("function 50")

      # Should complete in reasonable time
      {time_us, results} =
        :timer.tc(fn ->
          VectorStore.search(query_emb, limit: 10)
        end)

      assert length(results) == 10
      # Less than 1 second for 100 embeddings
      assert time_us < 1_000_000
    end
  end

  # Helper functions

  defp wait_for_ready(attempts \\ 50) do
    if Bumblebee.ready?() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(2000)
        wait_for_ready(attempts - 1)
      else
        flunk("Model did not become ready in time")
      end
    end
  end
end
