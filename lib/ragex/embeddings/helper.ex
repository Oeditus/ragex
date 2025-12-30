defmodule Ragex.Embeddings.Helper do
  @moduledoc """
  Helper functions to generate and store embeddings for analyzed code entities.

  This module bridges the gap between code analyzers and the embedding system,
  automatically generating embeddings for modules, functions, and other entities.
  """

  alias Ragex.Embeddings.{Bumblebee, TextGenerator}
  alias Ragex.Graph.Store

  require Logger

  @doc """
  Generates and stores embeddings for all entities in an analysis result.

  Takes the output from an analyzer and generates embeddings for:
  - Modules
  - Functions

  Returns `:ok` if embeddings were generated, or `{:error, reason}` if the
  model is not ready or embedding generation fails.
  """
  def generate_and_store_embeddings(analysis_result) do
    if Bumblebee.ready?() do
      try do
        # Generate embeddings for modules
        Enum.each(analysis_result.modules, fn module_data ->
          generate_module_embedding(module_data)
        end)

        # Generate embeddings for functions
        Enum.each(analysis_result.functions, fn function_data ->
          generate_function_embedding(function_data)
        end)

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
  """
  def generate_batch_embeddings(entities, entity_type) do
    if Bumblebee.ready?() do
      # Generate all texts first
      texts_with_ids =
        Enum.map(entities, fn entity ->
          text =
            case entity_type do
              :module -> TextGenerator.module_text(entity)
              :function -> TextGenerator.function_text(entity)
            end

          entity_id =
            case entity_type do
              :module -> entity.name
              :function -> {entity.module, entity.name, entity.arity}
            end

          {entity_id, text}
        end)

      # Batch generate embeddings
      texts = Enum.map(texts_with_ids, fn {_id, text} -> text end)

      case Bumblebee.embed_batch(texts) do
        {:ok, embeddings} ->
          # Store all embeddings
          Enum.zip(texts_with_ids, embeddings)
          |> Enum.each(fn {{entity_id, text}, embedding} ->
            Store.store_embedding(entity_type, entity_id, embedding, text)
          end)

          {:ok, length(embeddings)}

        {:error, reason} ->
          Logger.warning("Failed to generate batch embeddings: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :model_not_ready}
    end
  end

  @doc """
  Checks if the embedding system is available and ready.
  """
  def ready? do
    Bumblebee.ready?()
  end
end
