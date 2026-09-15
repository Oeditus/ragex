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

  alias Bumblebee.Text.TextEmbedding
  alias Ragex.Embeddings.Registry

  defmodule State do
    @moduledoc false
    defstruct [:serving, :host_serving, :tokenizer, :model, :model_info, ready: false]
  end

  @timeout :ragex
           |> Application.compile_env(:timeouts, [])
           |> Keyword.get(:bumblebee, 600_000)

  # Client API

  @doc """
  Returns `true` when the optional ML dependencies (`bumblebee`, `nx`, `exla`)
  are compiled and loadable.

  These are native/NIF-backed dependencies that cannot be loaded from inside
  an escript archive, so callers embedding Ragex as a library should check
  this before relying on embedding/semantic-search features.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(Bumblebee) and Code.ensure_loaded?(Nx) and Code.ensure_loaded?(EXLA)
  end

  @doc """
  Returns `true` when CUDA GPU acceleration is available via EXLA.
  """
  @spec cuda_available?() :: boolean()
  def cuda_available? do
    if available?() do
      try do
        _ = EXLA.Client.fetch!(:cuda)
        true
      rescue
        _ -> false
      catch
        _, _ -> false
      end
    else
      false
    end
  end

  @doc """
  Returns information about the EXLA execution backend and CUDA status.
  """
  @spec backend_info() :: map()
  def backend_info do
    if available?() do
      default_client =
        try do
          EXLA.Client.default_name()
        rescue
          _ -> :unknown
        end

      platforms =
        try do
          EXLA.Client.get_supported_platforms()
        rescue
          _ -> %{}
        end

      %{
        available: true,
        compiler: EXLA,
        default_client: default_client,
        cuda_available: Map.has_key?(platforms, :cuda),
        supported_platforms: platforms
      }
    else
      %{
        available: false,
        compiler: nil,
        default_client: nil,
        cuda_available: false,
        supported_platforms: %{}
      }
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Ragex.Embeddings.Behaviour
  def embed(text) when is_binary(text) do
    GenServer.call(__MODULE__, {:embed, text}, @timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @impl Ragex.Embeddings.Behaviour
  def embed_batch(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:embed_batch, texts}, @timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @impl Ragex.Embeddings.Behaviour
  def dimensions do
    GenServer.call(__MODULE__, :dimensions, @timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Returns the current model information.
  """
  @spec model_info() :: map() | {:error, term()}
  def model_info do
    GenServer.call(__MODULE__, :model_info, @timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Returns true if the model is loaded and ready.
  """
  @spec ready?() :: boolean()
  def ready? do
    GenServer.call(__MODULE__, :ready?, @timeout)
  catch
    :exit, {:noproc, _} -> false
    :exit, {:timeout, _} -> false
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
    result = generate_embedding(text, state)
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
    result = generate_embeddings_batch(texts, state)
    {:reply, result, state}
  end

  # Private Functions

  defp load_model(model_info) do
    Logger.info("Loading model from #{model_info.repo}...")

    # Load the tokenizer
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_info.repo})

    # Load the model
    low_memory = Application.get_env(:ragex, :low_memory, false)
    model_opts = if low_memory, do: [type: {:f, 16}], else: []
    {:ok, model} = Bumblebee.load_model({:hf, model_info.repo}, model_opts)

    # Create a serving for embeddings
    sequence_length = min(model_info.max_tokens, 512)

    exla_client =
      Application.get_env(:ragex, :exla_client) ||
        System.get_env("RAGEX_EXLA_CLIENT") ||
        System.get_env("EXLA_CLIENT")

    defn_options =
      cond do
        exla_client ->
          client_atom =
            if is_atom(exla_client), do: exla_client, else: String.to_atom(to_string(exla_client))

          [compiler: EXLA, client: client_atom]

        cuda_available?() ->
          [compiler: EXLA, client: :cuda]

        true ->
          [compiler: EXLA, client: :host]
      end

    try do
      serving = build_serving(model, tokenizer, sequence_length, defn_options)
      {:ok, serving, tokenizer, model}
    rescue
      e ->
        if defn_options[:client] == :cuda do
          Logger.warning(
            "Failed to initialize EXLA with CUDA (#{Exception.message(e)}). Falling back to host CPU..."
          )

          try do
            serving =
              build_serving(model, tokenizer, sequence_length, compiler: EXLA, client: :host)

            {:ok, serving, tokenizer, model}
          rescue
            fallback_err ->
              {:error, Exception.message(fallback_err)}
          end
        else
          {:error, Exception.message(e)}
        end
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp build_serving(model, tokenizer, sequence_length, defn_options) do
    TextEmbedding.text_embedding(model, tokenizer,
      output_attribute: :hidden_state,
      output_pool: :mean_pooling,
      embedding_processor: :l2_norm,
      compile: [batch_size: 32, sequence_length: sequence_length],
      defn_options: defn_options
    )
  end

  defp generate_embedding(text, state) do
    # Truncate very long texts to avoid OOM
    sliced_text = String.slice(text, 0, 5000)

    try do
      result = Nx.Serving.run(state.serving, sliced_text)
      {:ok, result.embedding |> Nx.to_flat_list()}
    rescue
      e ->
        fallback_generate_embedding(sliced_text, state, Exception.message(e))
    catch
      :exit, reason ->
        fallback_generate_embedding(sliced_text, state, inspect(reason))
    end
  end

  defp fallback_generate_embedding(sliced_text, state, error_reason) do
    if state.serving && state.model && state.tokenizer do
      Logger.warning(
        "CUDA/EXLA execution error (#{error_reason}). Attempting host CPU fallback..."
      )

      try do
        host_serving =
          state.host_serving ||
            build_serving(
              state.model,
              state.tokenizer,
              min(state.model_info.max_tokens, 512),
              compiler: EXLA,
              client: :host
            )

        result = Nx.Serving.run(host_serving, sliced_text)
        {:ok, result.embedding |> Nx.to_flat_list()}
      rescue
        e -> {:error, "CUDA and host fallback failed: #{Exception.message(e)}"}
      catch
        :exit, reason -> {:error, "CUDA and host fallback failed: #{inspect(reason)}"}
      end
    else
      {:error, error_reason}
    end
  end

  defp generate_embeddings_batch(texts, state) do
    sliced_texts = Enum.map(texts, &String.slice(&1, 0, 5000))

    try do
      results = Nx.Serving.run(state.serving, sliced_texts)

      embeddings =
        results
        |> Enum.map(fn result ->
          result.embedding |> Nx.to_flat_list()
        end)

      {:ok, embeddings}
    rescue
      e ->
        fallback_generate_embeddings_batch(sliced_texts, state, Exception.message(e))
    catch
      :exit, reason ->
        fallback_generate_embeddings_batch(sliced_texts, state, inspect(reason))
    end
  end

  defp fallback_generate_embeddings_batch(sliced_texts, state, error_reason) do
    if state.serving && state.model && state.tokenizer do
      Logger.warning(
        "CUDA/EXLA execution error (#{error_reason}). Attempting host CPU fallback..."
      )

      try do
        host_serving =
          state.host_serving ||
            build_serving(
              state.model,
              state.tokenizer,
              min(state.model_info.max_tokens, 512),
              compiler: EXLA,
              client: :host
            )

        results = Nx.Serving.run(host_serving, sliced_texts)

        embeddings =
          results
          |> Enum.map(fn result ->
            result.embedding |> Nx.to_flat_list()
          end)

        {:ok, embeddings}
      rescue
        e -> {:error, "CUDA and host fallback failed: #{Exception.message(e)}"}
      catch
        :exit, reason -> {:error, "CUDA and host fallback failed: #{inspect(reason)}"}
      end
    else
      {:error, error_reason}
    end
  end
end
