defmodule Ragex.Embeddings.IncrementalEmbeddingsTest do
  use ExUnit.Case, async: false

  alias Ragex.Embeddings.FileTracker
  alias Ragex.Embeddings.Helper

  setup do
    FileTracker.init()
    FileTracker.clear_all()
    :ok
  end

  describe "record_entity_hashes/2 and stale_entities_for_file/2" do
    test "all entities are stale on first call (no stored hashes)" do
      pairs = [
        {{:M, :f, 0}, "def f, do: :ok"},
        {{:M, :g, 1}, "def g(x), do: x"}
      ]

      stale = FileTracker.stale_entities_for_file("lib/m.ex", pairs)

      assert MapSet.member?(stale, {:M, :f, 0})
      assert MapSet.member?(stale, {:M, :g, 1})
    end

    test "unchanged entities are not stale after recording" do
      pairs = [
        {{:M, :f, 0}, "def f, do: :ok"},
        {{:M, :g, 1}, "def g(x), do: x"}
      ]

      FileTracker.record_entity_hashes("lib/m.ex", pairs)

      stale = FileTracker.stale_entities_for_file("lib/m.ex", pairs)

      assert MapSet.size(stale) == 0
    end

    test "only the modified entity is stale after a body change" do
      pairs = [
        {{:M, :f, 0}, "def f, do: :ok"},
        {{:M, :g, 1}, "def g(x), do: x"}
      ]

      FileTracker.record_entity_hashes("lib/m.ex", pairs)

      updated_pairs = [
        {{:M, :f, 0}, "def f, do: :ok"},
        # g body changed
        {{:M, :g, 1}, "def g(x), do: x + 1"}
      ]

      stale = FileTracker.stale_entities_for_file("lib/m.ex", updated_pairs)

      refute MapSet.member?(stale, {:M, :f, 0})
      assert MapSet.member?(stale, {:M, :g, 1})
    end

    test "a new entity (not in stored hashes) is always stale" do
      existing = [{{:M, :f, 0}, "def f, do: :ok"}]
      FileTracker.record_entity_hashes("lib/m.ex", existing)

      pairs_with_new = existing ++ [{{:M, :h, 2}, "def h(a, b), do: a + b"}]
      stale = FileTracker.stale_entities_for_file("lib/m.ex", pairs_with_new)

      refute MapSet.member?(stale, {:M, :f, 0})
      assert MapSet.member?(stale, {:M, :h, 2})
    end

    test "hashes are per-file — same entity in two files tracked independently" do
      body = "def f, do: :ok"

      FileTracker.record_entity_hashes("lib/a.ex", [{{:A, :f, 0}, body}])
      FileTracker.record_entity_hashes("lib/b.ex", [{{:B, :f, 0}, body}])

      # Update entity in b only
      stale_a = FileTracker.stale_entities_for_file("lib/a.ex", [{{:A, :f, 0}, body}])

      stale_b =
        FileTracker.stale_entities_for_file("lib/b.ex", [{{:B, :f, 0}, "def f, do: :changed"}])

      assert MapSet.size(stale_a) == 0
      assert MapSet.member?(stale_b, {:B, :f, 0})
    end

    test "clear_all/0 resets entity hashes so all entities become stale again" do
      pairs = [{{:M, :f, 0}, "def f, do: :ok"}]
      FileTracker.record_entity_hashes("lib/m.ex", pairs)

      stale_before = FileTracker.stale_entities_for_file("lib/m.ex", pairs)
      assert MapSet.size(stale_before) == 0

      FileTracker.clear_all()

      stale_after = FileTracker.stale_entities_for_file("lib/m.ex", pairs)
      assert MapSet.member?(stale_after, {:M, :f, 0})
    end
  end

  describe "generate_batch_embeddings/3 with :only filter" do
    # We test filter behaviour without a real Bumblebee — the function returns
    # {:error, :model_not_ready} when the model is not running, but must NOT
    # raise and must NOT call Store.store_embedding for filtered-out entities.

    test "returns {:error, :model_not_ready} rather than raising when model is down" do
      result =
        Helper.generate_batch_embeddings([], :function, only: MapSet.new())

      # Either {:ok, 0} (nothing to do) or {:error, :model_not_ready}
      assert result in [{:ok, 0}, {:error, :model_not_ready}]
    end

    test "empty only-set short-circuits without hitting the embedding model" do
      entities = [
        %{module: :M, name: :f, arity: 0, doc: "doc", source: "def f, do: :ok"}
      ]

      result =
        Helper.generate_batch_embeddings(entities, :function, only: MapSet.new())

      assert result == {:ok, 0}
    end
  end
end
