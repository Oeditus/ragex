defmodule Ragex.Embeddings.Registry do
  @moduledoc """
  Registry of available embedding models with metadata.

  Provides model definitions, metadata, and lookup functions for
  different embedding models that can be used with Ragex.
  """

  @type model_id :: atom()
  @type model_info :: %{
          id: model_id(),
          name: String.t(),
          repo: String.t(),
          dimensions: pos_integer(),
          max_tokens: pos_integer(),
          description: String.t(),
          type: :sentence_transformer | :code_model | :multilingual,
          recommended_for: [String.t()]
        }

  @models %{
    # Default model - good balance of speed and quality
    all_minilm_l6_v2: %{
      id: :all_minilm_l6_v2,
      name: "all-MiniLM-L6-v2",
      repo: "sentence-transformers/all-MiniLM-L6-v2",
      dimensions: 384,
      max_tokens: 256,
      description: "Lightweight sentence transformer model with good performance",
      type: :sentence_transformer,
      recommended_for: ["general purpose", "small codebases", "fast inference"]
    },

    # Higher quality, larger model
    all_mpnet_base_v2: %{
      id: :all_mpnet_base_v2,
      name: "all-mpnet-base-v2",
      repo: "sentence-transformers/all-mpnet-base-v2",
      dimensions: 768,
      max_tokens: 384,
      description: "High-quality sentence transformer with better semantic understanding",
      type: :sentence_transformer,
      recommended_for: ["large codebases", "high accuracy", "deep semantic search"]
    },

    # Code-specific model
    codebert_base: %{
      id: :codebert_base,
      name: "CodeBERT Base",
      repo: "microsoft/codebert-base",
      dimensions: 768,
      max_tokens: 512,
      description: "Pre-trained model on code and natural language",
      type: :code_model,
      recommended_for: ["code understanding", "programming languages", "code similarity"]
    },

    # Multilingual support
    paraphrase_multilingual: %{
      id: :paraphrase_multilingual,
      name: "paraphrase-multilingual-MiniLM-L12-v2",
      repo: "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
      dimensions: 384,
      max_tokens: 128,
      description: "Multilingual sentence embeddings for 50+ languages",
      type: :multilingual,
      recommended_for: ["multilingual codebases", "international teams", "non-English docs"]
    }
  }

  @doc """
  Returns all available models.
  """
  @spec all() :: [model_info()]
  def all do
    @models |> Map.values() |> Enum.sort_by(& &1.id)
  end

  @doc """
  Gets a model by ID.

  ## Examples

      iex> Registry.get(:all_minilm_l6_v2)
      {:ok, %{id: :all_minilm_l6_v2, ...}}
      
      iex> Registry.get(:invalid)
      {:error, :not_found}
  """
  @spec get(model_id()) :: {:ok, model_info()} | {:error, :not_found}
  def get(model_id) when is_atom(model_id) do
    case Map.get(@models, model_id) do
      nil -> {:error, :not_found}
      model -> {:ok, model}
    end
  end

  @doc """
  Gets a model by ID, raises if not found.
  """
  @spec get!(model_id()) :: model_info()
  def get!(model_id) do
    case get(model_id) do
      {:ok, model} -> model
      {:error, :not_found} -> raise ArgumentError, "Unknown model ID: #{inspect(model_id)}"
    end
  end

  @doc """
  Finds a model by repository name.

  ## Examples

      iex> Registry.find_by_repo("sentence-transformers/all-MiniLM-L6-v2")
      {:ok, %{id: :all_minilm_l6_v2, ...}}
  """
  @spec find_by_repo(String.t()) :: {:ok, model_info()} | {:error, :not_found}
  def find_by_repo(repo) when is_binary(repo) do
    result =
      @models
      |> Map.values()
      |> Enum.find(&(&1.repo == repo))

    case result do
      nil -> {:error, :not_found}
      model -> {:ok, model}
    end
  end

  @doc """
  Lists models by type.

  ## Examples

      iex> Registry.by_type(:code_model)
      [%{id: :codebert_base, ...}]
  """
  @spec by_type(:sentence_transformer | :code_model | :multilingual) :: [model_info()]
  def by_type(type) do
    @models
    |> Map.values()
    |> Enum.filter(&(&1.type == type))
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  Returns the default model ID.
  """
  @spec default() :: model_id()
  def default, do: :all_minilm_l6_v2

  @doc """
  Validates if a model ID is valid.
  """
  @spec valid?(model_id()) :: boolean()
  def valid?(model_id) when is_atom(model_id) do
    Map.has_key?(@models, model_id)
  end

  @doc """
  Gets dimension count for a model.
  """
  @spec dimensions(model_id()) :: {:ok, pos_integer()} | {:error, :not_found}
  def dimensions(model_id) do
    case get(model_id) do
      {:ok, model} -> {:ok, model.dimensions}
      error -> error
    end
  end

  @doc """
  Checks if two models are compatible (same dimensions).
  """
  @spec compatible?(model_id(), model_id()) :: boolean()
  def compatible?(model_id1, model_id2) do
    with {:ok, model1} <- get(model_id1),
         {:ok, model2} <- get(model_id2) do
      model1.dimensions == model2.dimensions
    else
      _ -> false
    end
  end

  @doc """
  Returns model recommendations as a formatted string.
  """
  @spec recommendations() :: String.t()
  def recommendations do
    """
    Embedding Model Recommendations:

    1. all_minilm_l6_v2 (Default)
       - Best for: Small to medium codebases
       - Speed: Fast (384 dimensions)
       - Quality: Good general-purpose embeddings

    2. all_mpnet_base_v2
       - Best for: Large codebases requiring high accuracy
       - Speed: Moderate (768 dimensions)
       - Quality: Excellent semantic understanding

    3. codebert_base
       - Best for: Code-specific tasks and similarity
       - Speed: Moderate (768 dimensions)
       - Quality: Optimized for programming languages

    4. paraphrase_multilingual
       - Best for: International teams, non-English docs
       - Speed: Fast (384 dimensions)
       - Quality: Good for 50+ languages

    Configuration:
      config :ragex, :embedding_model, :all_minilm_l6_v2

    Or via environment variable:
      export RAGEX_EMBEDDING_MODEL=codebert_base
    """
  end
end
