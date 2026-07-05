defmodule Ragex.Embeddings.ChunkerTest do
  use ExUnit.Case, async: true

  alias Ragex.Embeddings.Chunker

  describe "split/2" do
    test "returns a single chunk for short text" do
      text = Enum.map_join(1..10, "\n", &"line #{&1}")
      result = Chunker.split(text, min_lines: 30)

      assert length(result) == 1
      assert elem(hd(result), 0) == 0
    end

    test "splits long text into multiple chunks" do
      # 120 lines, default chunk_lines=60, overlap=15 → stride=45
      # chunks: 0, 45, 90 → 3 chunks
      text = Enum.map_join(1..120, "\n", &"line #{&1}")
      chunks = Chunker.split(text, chunk_lines: 60, overlap_lines: 15, min_lines: 30)

      assert length(chunks) >= 2
    end

    test "chunks are indexed sequentially from 0" do
      text = Enum.map_join(1..120, "\n", &"line #{&1}")
      chunks = Chunker.split(text, chunk_lines: 60, overlap_lines: 15, min_lines: 30)
      indices = Enum.map(chunks, &elem(&1, 0))

      assert indices == Enum.to_list(0..(length(chunks) - 1))
    end

    test "adjacent chunks share overlap_lines worth of content" do
      lines = Enum.map(1..120, &"line #{&1}")
      text = Enum.join(lines, "\n")
      chunks = Chunker.split(text, chunk_lines: 60, overlap_lines: 15, min_lines: 30)

      # The second chunk should contain lines that the first chunk ends with
      {_, first_text} = Enum.at(chunks, 0)
      {_, second_text} = Enum.at(chunks, 1)

      first_lines = String.split(first_text, "\n")
      second_lines = String.split(second_text, "\n")

      # last 15 lines of first chunk should appear at start of second
      overlap_start = Enum.slice(first_lines, -15, 15)
      second_start = Enum.slice(second_lines, 0, 15)

      assert overlap_start == second_start
    end

    test "prepends header to every chunk when provided" do
      text = Enum.map_join(1..120, "\n", &"line #{&1}")
      header = "Module: MyModule"

      chunks =
        Chunker.split(text, header: header, chunk_lines: 60, overlap_lines: 15, min_lines: 30)

      Enum.each(chunks, fn {_idx, chunk_text} ->
        assert String.starts_with?(chunk_text, header)
      end)
    end

    test "each chunk text is non-empty" do
      text = Enum.map_join(1..60, "\n", &"line #{&1}")
      chunks = Chunker.split(text, chunk_lines: 20, overlap_lines: 5, min_lines: 10)

      Enum.each(chunks, fn {_idx, text} ->
        assert String.length(text) > 0
      end)
    end

    test "returns single chunk when text equals min_lines threshold minus one" do
      # Exactly min_lines - 1 lines → should NOT chunk
      text = Enum.map_join(1..29, "\n", &"line #{&1}")
      chunks = Chunker.split(text, min_lines: 30)
      assert length(chunks) == 1
    end
  end

  describe "chunk_key/3" do
    test "builds a 3-tuple key" do
      key = Chunker.chunk_key(:function, {:MyMod, :my_func, 1}, 2)
      assert key == {:function, {:MyMod, :my_func, 1}, 2}
    end

    test "chunk_key?/1 recognizes chunk keys" do
      key = Chunker.chunk_key(:function, {:MyMod, :func, 0}, 0)
      assert Chunker.chunk_key?(key)
    end

    test "chunk_key?/1 rejects non-chunk keys" do
      refute Chunker.chunk_key?({:function, {:MyMod, :func, 0}})
      refute Chunker.chunk_key?(:module)
      refute Chunker.chunk_key?("string")
    end
  end

  describe "parent_of/1" do
    test "extracts parent from a chunk key" do
      key = Chunker.chunk_key(:module, SomeModule, 3)
      assert Chunker.parent_of(key) == {:module, SomeModule}
    end

    test "returns nil for a non-chunk key" do
      assert Chunker.parent_of({:function, {:Mod, :func, 0}}) == nil
      assert Chunker.parent_of(:module) == nil
    end
  end

  describe "defaults/0" do
    test "returns a keyword list with required keys" do
      defaults = Chunker.defaults()
      assert Keyword.has_key?(defaults, :chunk_lines)
      assert Keyword.has_key?(defaults, :overlap_lines)
      assert Keyword.has_key?(defaults, :min_lines)
    end

    test "overlap is less than chunk_lines" do
      defaults = Chunker.defaults()
      assert defaults[:overlap_lines] < defaults[:chunk_lines]
    end
  end
end
