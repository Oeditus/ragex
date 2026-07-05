defmodule Ragex.Embeddings.Helper do
  @moduledoc """
  Helper functions to generate and store embeddings for analyzed code entities.

  This module bridges the gap between code analyzers and the embedding system,
  automatically generating embeddings for modules, functions, and other entities.

  ## Chunking

  Large entities (modules or functions whose embeddable text exceeds
  `Chunker.defaults()[:min_lines]` lines) are also stored as per-chunk
  embeddings under node type `:chunk`. Each chunk key is
  `{parent_type, parent_id, chunk_index}`.

  The entity-level embedding is always stored as well for backward
  compatibility with `graph_first` retrieval, which looks up embeddings by
  exact entity key. Chunk embeddings are used by semantic and hybrid search
  via the `:include_chunks` option on `VectorStore.search/2`.
  """

  alias Ragex.Embeddings.{Bumblebee, Chunker, TextGenerator}
  alias Ragex.Graph.Store

  require Logger

  @doc """
  Generates and stores embeddings for all entities in an analysis result.

  Takes the output from an analyzer and generates embeddings for:
  - Modules
  - Functions

  Returns `:ok` if embeddings were generated, or `{:error, reason}` if the
  model is not ready or embedding generation fails.

  ## Options

  - `:only` - `MapSet` of entity IDs whose embeddings should be (re)generated.
    When `nil` (default) all entities are embedded. Set this to the result of
    `FileTracker.stale_entities_for_file/2` to skip unchanged functions and
    avoid redundant re-embeddings on incremental re-analysis.
  """
  def generate_and_store_embeddings(analysis_result, opts \\ []) do
    only = Keyword.get(opts, :only)

    if Bumblebee.ready?() do
      try do
        module_count = length(analysis_result.modules)
        function_count = length(analysis_result.functions)

        Logger.debug(
          "Generating embeddings for #{module_count} modules and #{function_count} functions" <>
            if(only, do: " (#{MapSet.size(only)} stale)", else: "")
        )

        embed_opts = [only: only]

        if module_count > 0 do
          generate_batch_embeddings(analysis_result.modules, :module, embed_opts)
          generate_batch_chunk_embeddings(analysis_result.modules, :module, embed_opts)
        end

        if function_count > 0 do
          analysis_result.functions
          |> Enum.chunk_every(32)
          |> Enum.each(fn batch ->
            generate_batch_embeddings(batch, :function, embed_opts)
            generate_batch_chunk_embeddings(batch, :function, embed_opts)
          end)
        end

        Logger.info("Embeddings generated for #{module_count + function_count} entities")

        :ok
      rescue
        e ->
          Logger.warning("Failed to generate embeddings: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end
    else
      Logger.debug("Embedding model not ready, skipping embedding generation")
      {:error, :model_not_ready}
    end
  end

  @doc """
  Generates and stores an embedding for a single module.
  """
  def generate_module_embedding(module_data) do
    text = TextGenerator.module_text(module_data)

    case Bumblebee.embed(text) do
      {:ok, embedding} ->
        Store.store_embedding(:module, module_data.name, embedding, text)
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to generate module embedding for #{module_data.name}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Generates and stores an embedding for a single function.
  """
  def generate_function_embedding(function_data) do
    text = TextGenerator.function_text(function_data)

    # Function ID is {module, name, arity}
    function_id = {function_data.module, function_data.name, function_data.arity}

    case Bumblebee.embed(text) do
      {:ok, embedding} ->
        Store.store_embedding(:function, function_id, embedding, text)
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to generate function embedding for #{inspect(function_id)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Generates embeddings for a batch of entities efficiently.

  Uses batch embedding to process multiple entities at once for better performance.

  ## Options

  - `:only` - `MapSet` of entity IDs to embed. When `nil` (default) all
    entities in the batch are embedded. Pass the result of
    `FileTracker.stale_entities_for_file/2` to skip unchanged functions.
  """
  def generate_batch_embeddings(entities, entity_type, opts \\ []) do
    only = Keyword.get(opts, :only)

    cond do
      # Short-circuit: caller explicitly said "embed nothing" — skip before touching Bumblebee
      only != nil and MapSet.size(only) == 0 ->
        {:ok, 0}

      not Bumblebee.ready?() ->
        {:error, :model_not_ready}

      true ->
        # Compute entity_id first, filter by `only`, then generate text only for kept entities
        texts_with_ids =
          entities
          |> Enum.map(fn entity ->
            entity_id =
              case entity_type do
                :module -> entity.name
                :function -> {entity.module, entity.name, entity.arity}
              end

            {entity_id, entity}
          end)
          |> Enum.filter(fn {entity_id, _entity} ->
            only == nil or MapSet.member?(only, entity_id)
          end)
          |> Enum.map(fn {entity_id, entity} ->
            text =
              case entity_type do
                :module -> TextGenerator.module_text(entity)
                :function -> TextGenerator.function_text(entity)
              end

            {entity_id, text}
          end)

        if texts_with_ids == [] do
          {:ok, 0}
        else
          texts = Enum.map(texts_with_ids, fn {_id, text} -> text end)

          case Bumblebee.embed_batch(texts) do
            {:ok, embeddings} ->
              Enum.zip(texts_with_ids, embeddings)
              |> Enum.each(fn {{entity_id, text}, embedding} ->
                Store.store_embedding(entity_type, entity_id, embedding, text)
              end)

              {:ok, length(embeddings)}

            {:error, reason} ->
              Logger.warning("Failed to generate batch embeddings: #{inspect(reason)}")
              {:error, reason}
          end
        end
    end
  end

  @doc """
  Checks if the embedding system is available and ready.
  """
  def ready? do
    Bumblebee.ready?()
  end

  # ---------------------------------------------------------------------------
  # Chunk embedding generation
  # ---------------------------------------------------------------------------

  @doc """
  Generate and store chunk embeddings for a single entity text.

  Splits `text` into overlapping windows via `Chunker.split/2`, embeds each
  window in one batch call, and stores them under node type `:chunk` with
  compound keys `{parent_type, parent_id, chunk_index}`.

  Returns `{:ok, chunk_count}` when chunks are stored, or `:skip` when the
  text is short enough that a single entity embedding already suffices.
  """
  @spec generate_chunk_embeddings(atom(), term(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | :skip | {:error, term()}
  def generate_chunk_embeddings(entity_type, entity_id, text, opts \\ []) do
    header = opts[:chunk_header] || ""

    chunk_opts =
      Keyword.merge(
        Chunker.defaults(),
        Keyword.take(opts, [:chunk_lines, :overlap_lines, :min_lines])
      )

    chunk_opts = Keyword.put(chunk_opts, :header, header)

    chunks = Chunker.split(text, chunk_opts)

    if length(chunks) <= 1 do
      :skip
    else
      chunk_texts = Enum.map(chunks, &elem(&1, 1))

      case Bumblebee.embed_batch(chunk_texts) do
        {:ok, embeddings} ->
          chunks
          |> Enum.zip(embeddings)
          |> Enum.each(fn {{idx, chunk_text}, embedding} ->
            chunk_key = Chunker.chunk_key(entity_type, entity_id, idx)
            Store.store_embedding(:chunk, chunk_key, embedding, chunk_text)
          end)

          {:ok, length(chunks)}

        {:error, reason} ->
          Logger.warning(
            "Failed to generate chunk embeddings for #{inspect({entity_type, entity_id})}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  @doc """
  Generate chunk embeddings for every entity in a batch.

  Called automatically after `generate_batch_embeddings/2`. Can also be called
  independently.

  ## Options

  - `:only` - `MapSet` of entity IDs to embed. Entities not in the set are
    skipped. Pass `nil` (default) to process all entities.
  """
  @spec generate_batch_chunk_embeddings([map()], atom(), keyword()) :: :ok
  def generate_batch_chunk_embeddings(entities, entity_type, opts \\ []) do
    only = Keyword.get(opts, :only)

    Enum.each(entities, fn entity ->
      text =
        case entity_type do
          :module -> TextGenerator.module_text(entity)
          :function -> TextGenerator.function_text(entity)
          _ -> nil
        end

      entity_id =
        case entity_type do
          :module -> entity.name
          :function -> {entity.module, entity.name, entity.arity}
          _ -> nil
        end

      if text && entity_id && (only == nil or MapSet.member?(only, entity_id)) do
        generate_chunk_embeddings(entity_type, entity_id, text)
      end
    end)

    :ok
  end
end
