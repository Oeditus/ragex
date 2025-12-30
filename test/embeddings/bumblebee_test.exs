defmodule Ragex.Embeddings.BumblebeeTest do
  use ExUnit.Case, async: false

  alias Ragex.Embeddings.Bumblebee

  @moduletag :embeddings
  # Embedding model can take time to load
  @moduletag timeout: 120_000

  describe "embed/1" do
    test "generates embedding for simple text" do
      # Wait for model to be ready
      wait_for_ready()

      {:ok, embedding} = Bumblebee.embed("Hello, world!")

      assert is_list(embedding)
      assert length(embedding) == 384
      assert Enum.all?(embedding, &is_float/1)
    end

    test "generates embedding for code description" do
      wait_for_ready()

      text =
        "Function: calculate_sum/2. Module: Math. Documentation: Calculates the sum of two numbers."

      {:ok, embedding} = Bumblebee.embed(text)

      assert length(embedding) == 384
    end

    test "handles empty string" do
      wait_for_ready()

      {:ok, embedding} = Bumblebee.embed("")

      assert is_list(embedding)
      assert length(embedding) == 384
    end

    test "handles very long text by truncating" do
      wait_for_ready()

      # Create a text longer than the 5000 char limit
      long_text = String.duplicate("a", 6000)
      {:ok, embedding} = Bumblebee.embed(long_text)

      assert length(embedding) == 384
    end

    test "generates similar embeddings for similar text" do
      wait_for_ready()

      {:ok, emb1} = Bumblebee.embed("Calculate the sum of two numbers")
      {:ok, emb2} = Bumblebee.embed("Add two numbers together")
      {:ok, emb3} = Bumblebee.embed("Parse JSON from a string")

      # Similarity between emb1 and emb2 should be higher than emb1 and emb3
      sim_12 = cosine_similarity(emb1, emb2)
      sim_13 = cosine_similarity(emb1, emb3)

      assert sim_12 > sim_13
    end

    test "returns error when model not ready" do
      # This test assumes the model might not be ready immediately on startup
      # In practice, we wait for ready in other tests

      # Just verify the function doesn't crash
      result = Bumblebee.embed("test")

      assert match?({:ok, _}, result) or match?({:error, :model_not_ready}, result)
    end
  end

  describe "embed_batch/1" do
    test "generates embeddings for multiple texts" do
      wait_for_ready()

      texts = [
        "First text",
        "Second text",
        "Third text"
      ]

      {:ok, embeddings} = Bumblebee.embed_batch(texts)

      assert length(embeddings) == 3

      assert Enum.all?(embeddings, fn emb ->
               is_list(emb) and length(emb) == 384
             end)
    end

    test "handles empty list" do
      wait_for_ready()

      {:ok, embeddings} = Bumblebee.embed_batch([])

      assert embeddings == []
    end
  end

  describe "dimensions/0" do
    test "returns correct dimension count" do
      assert Bumblebee.dimensions() == 384
    end
  end

  describe "ready?/0" do
    test "returns boolean status" do
      result = Bumblebee.ready?()
      assert is_boolean(result)
    end

    test "eventually becomes ready" do
      wait_for_ready()
      assert Bumblebee.ready?() == true
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

  defp cosine_similarity(vec1, vec2) do
    dot_product =
      Enum.zip(vec1, vec2)
      |> Enum.map(fn {a, b} -> a * b end)
      |> Enum.sum()

    magnitude1 = :math.sqrt(Enum.map(vec1, fn x -> x * x end) |> Enum.sum())
    magnitude2 = :math.sqrt(Enum.map(vec2, fn x -> x * x end) |> Enum.sum())

    dot_product / (magnitude1 * magnitude2)
  end
end
