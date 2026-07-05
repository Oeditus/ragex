defmodule Ragex.Embeddings.Chunker do
  @moduledoc """
  Splits large source texts into overlapping windows for fine-grained embedding.

  A single embedding for a 500-line module averages over too much semantic
  territory. This module produces multiple chunk records per entity, each with
  its own embedding, all pointing back to the parent entity.

  ## Chunk record format

  Each chunk is stored in the embedding table under node type `:chunk` with a
  compound key `{parent_type, parent_id, chunk_index}`, and text that retains
  the parent's identifier header for context anchoring.

  ## Strategy

  - Splits on line boundaries to avoid breaking mid-token.
  - Uses a sliding window with overlap so context around split points is
    preserved in adjacent chunks.
  - Entities shorter than `min_lines` are stored as a single embedding using
    the normal (non-chunk) path.
  """

  @default_chunk_lines 60
  @default_overlap_lines 15
  @min_lines_to_chunk 30

  @type parent_type :: :module | :function | atom()
  @type parent_id :: term()
  @type chunk_key :: {parent_type(), parent_id(), non_neg_integer()}

  @doc """
  Split `text` into overlapping line-based windows.

  Returns a list of `{chunk_index, chunk_text}` pairs. Always returns at
  least one chunk. Returns a single-element list when the text is shorter
  than `min_lines` — callers can detect this and skip chunk storage.

  ## Options

  - `:chunk_lines`   - lines per chunk window (default: #{@default_chunk_lines})
  - `:overlap_lines` - lines shared between adjacent windows (default: #{@default_overlap_lines})
  - `:min_lines`     - minimum lines before chunking is applied (default: #{@min_lines_to_chunk})
  - `:header`        - prepended to every chunk for context anchoring (default: "")
  """
  @spec split(String.t(), keyword()) :: [{non_neg_integer(), String.t()}]
  def split(text, opts \\ []) do
    chunk_lines = Keyword.get(opts, :chunk_lines, @default_chunk_lines)
    overlap = Keyword.get(opts, :overlap_lines, @default_overlap_lines)
    min_lines = Keyword.get(opts, :min_lines, @min_lines_to_chunk)
    header = Keyword.get(opts, :header, "")

    lines = String.split(text, "\n")
    total = length(lines)

    if total < min_lines do
      [{0, text}]
    else
      stride = max(chunk_lines - overlap, 1)

      0
      |> Stream.iterate(&(&1 + stride))
      |> Stream.take_while(&(&1 < total))
      |> Enum.with_index()
      |> Enum.map(fn {start, idx} ->
        window =
          lines
          |> Enum.slice(start, chunk_lines)
          |> Enum.join("\n")

        chunk_text = if header != "", do: header <> "\n" <> window, else: window
        {idx, chunk_text}
      end)
    end
  end

  @doc """
  Build a chunk key suitable for `Store.store_embedding/4`.

  The key encodes the parent identity and chunk index so all chunks for an
  entity can be found by scanning the embeddings table.
  """
  @spec chunk_key(parent_type(), parent_id(), non_neg_integer()) :: chunk_key()
  def chunk_key(parent_type, parent_id, index) do
    {parent_type, parent_id, index}
  end

  @doc """
  Return the parent `{type, id}` for a chunk key, or `nil` for non-chunk keys.
  """
  @spec parent_of(chunk_key()) :: {parent_type(), parent_id()} | nil
  def parent_of({parent_type, parent_id, index})
      when is_atom(parent_type) and is_integer(index),
      do: {parent_type, parent_id}

  def parent_of(_), do: nil

  @doc """
  True when the node key looks like a chunk key (3-tuple with integer last element).
  """
  @spec chunk_key?({parent_type(), parent_id(), non_neg_integer()} | term()) :: boolean()
  def chunk_key?({_type, _id, index}) when is_integer(index), do: true
  def chunk_key?(_), do: false

  @doc """
  Default chunking options as a keyword list. Useful for tests and documentation.
  """
  @spec defaults() :: keyword()
  def defaults do
    [
      chunk_lines: @default_chunk_lines,
      overlap_lines: @default_overlap_lines,
      min_lines: @min_lines_to_chunk
    ]
  end
end
