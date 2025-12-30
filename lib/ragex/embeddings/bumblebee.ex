defmodule Ragex.Embeddings.Bumblebee do
  @moduledoc """
  Embedding adapter using Bumblebee with configurable models.

  Supports multiple embedding models from the Registry:
  - all_minilm_l6_v2 (default): 384-dimensional, fast
  - all_mpnet_base_v2: 768-dimensional, high quality
  - codebert_base: 768-dimensional, code-specific
  - paraphrase_multilingual: 384-dimensional, multilingual

  Model is configured via config.exs or RAGEX_EMBEDDING_MODEL environment variable.
  Model weights are downloaded on first use and cached locally.
  """

  @behaviour Ragex.Embeddings.Behaviour

  use GenServer
  require Logger

  alias Ragex.Embeddings.Registry

  defmodule State do
    @moduledoc false
    defstruct [:serving, :tokenizer, :model, :model_info, ready: false]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Ragex.Embeddings.Behaviour
  def embed(text) when is_binary(text) do
    GenServer.call(__MODULE__, {:embed, text}, :infinity)
  end

  @impl Ragex.Embeddings.Behaviour
  def embed_batch(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:embed_batch, texts}, :infinity)
  end

  @impl Ragex.Embeddings.Behaviour
  def dimensions do
    GenServer.call(__MODULE__, :dimensions)
  end

  @doc """
  Returns the current model information.
  """
  def model_info do
    GenServer.call(__MODULE__, :model_info)
  end

  @doc """
  Returns true if the model is loaded and ready.
  """
  def ready? do
    GenServer.call(__MODULE__, :ready?)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Get configured model
    model_id = Application.get_env(:ragex, :embedding_model, Registry.default())

    case Registry.get(model_id) do
      {:ok, model_info} ->
        Logger.info("Initializing Bumblebee with model: #{model_info.name}")
        Logger.info("Model dimensions: #{model_info.dimensions}")

        # Load model asynchronously to avoid blocking supervision tree startup
        send(self(), {:load_model, model_info})

        {:ok, %State{model_info: model_info}}

      {:error, :not_found} ->
        Logger.error("Invalid embedding model configured: #{inspect(model_id)}")
        Logger.info("Falling back to default model: #{Registry.default()}")

        model_info = Registry.get!(Registry.default())
        send(self(), {:load_model, model_info})

        {:ok, %State{model_info: model_info}}
    end
  end

  @impl true
  def handle_info({:load_model, model_info}, state) do
    case load_model(model_info) do
      {:ok, serving, tokenizer, model} ->
        Logger.info("Bumblebee embedding model loaded successfully")

        new_state = %State{
          serving: serving,
          tokenizer: tokenizer,
          model: model,
          model_info: model_info,
          ready: true
        }

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to load Bumblebee model: #{inspect(reason)}")
        # Retry after 5 seconds
        Process.send_after(self(), {:load_model, model_info}, 5000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state.ready, state}
  end

  @impl true
  def handle_call(:dimensions, _from, state) do
    dims = if state.model_info, do: state.model_info.dimensions, else: 0
    {:reply, dims, state}
  end

  @impl true
  def handle_call(:model_info, _from, state) do
    {:reply, state.model_info, state}
  end

  @impl true
  def handle_call({:embed, _text}, _from, %State{ready: false} = state) do
    {:reply, {:error, :model_not_ready}, state}
  end

  @impl true
  def handle_call({:embed, text}, _from, state) do
    result = generate_embedding(text, state.serving)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:embed_batch, _texts}, _from, %State{ready: false} = state) do
    {:reply, {:error, :model_not_ready}, state}
  end

  @impl true
  def handle_call({:embed_batch, []}, _from, state) do
    {:reply, {:ok, []}, state}
  end

  @impl true
  def handle_call({:embed_batch, texts}, _from, state) do
    result = generate_embeddings_batch(texts, state.serving)
    {:reply, result, state}
  end

  # Private Functions

  defp load_model(model_info) do
    try do
      Logger.info("Loading model from #{model_info.repo}...")

      # Load the tokenizer
      {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_info.repo})

      # Load the model
      {:ok, model} = Bumblebee.load_model({:hf, model_info.repo})

      # Create a serving for embeddings
      # Adjust sequence length based on model's max_tokens
      sequence_length = min(model_info.max_tokens, 512)

      serving =
        Bumblebee.Text.TextEmbedding.text_embedding(model, tokenizer,
          output_attribute: :hidden_state,
          output_pool: :mean_pooling,
          embedding_processor: :l2_norm,
          compile: [batch_size: 32, sequence_length: sequence_length],
          defn_options: [compiler: EXLA]
        )

      {:ok, serving, tokenizer, model}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  defp generate_embedding(text, serving) do
    try do
      # Truncate very long texts to avoid OOM
      text = String.slice(text, 0, 5000)

      result = Nx.Serving.run(serving, text)

      # Extract the embedding tensor and convert to list
      embedding = result.embedding |> Nx.to_flat_list()

      {:ok, embedding}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  defp generate_embeddings_batch(texts, serving) do
    try do
      # Truncate texts
      texts = Enum.map(texts, &String.slice(&1, 0, 5000))

      results = Nx.Serving.run(serving, texts)

      # Extract embeddings
      embeddings =
        results
        |> Enum.map(fn result ->
          result.embedding |> Nx.to_flat_list()
        end)

      {:ok, embeddings}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end
end
