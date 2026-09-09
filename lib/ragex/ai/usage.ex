defmodule Ragex.AI.Usage do
  @moduledoc """
  Tracks AI provider usage including requests, tokens, and estimated costs.

  Maintains statistics per provider with time-windowed tracking for rate limiting.

  ## Configuration

      config :ragex, :ai_limits,
        max_requests_per_minute: 60,
        max_requests_per_hour: 1000,
        max_tokens_per_day: 100_000

  ## Cost Estimation

  Pricing as of January 2026 (subject to change):

  - OpenAI GPT-4-turbo: $0.01/1K input, $0.03/1K output
  - OpenAI GPT-3.5-turbo: $0.0005/1K input, $0.0015/1K output
  - Anthropic Claude-3-Opus: $0.015/1K input, $0.075/1K output
  - Anthropic Claude-3-Sonnet: $0.003/1K input, $0.015/1K output
  - Anthropic Claude-3-Haiku: $0.00025/1K input, $0.00125/1K output
  - DeepSeek R1: $0.001/1K input, $0.002/1K output
  - Ollama: Free (local)
  """

  use GenServer
  require Logger

  @table_name :ragex_ai_usage
  @window_table :ragex_ai_usage_windows

  # Pricing per 1K tokens (input, output) in USD
  @pricing %{
    openai: %{
      "gpt-4" => {0.03, 0.06},
      "gpt-4-turbo" => {0.01, 0.03},
      "gpt-4-turbo-preview" => {0.01, 0.03},
      "gpt-3.5-turbo" => {0.0005, 0.0015},
      "gpt-3.5-turbo-16k" => {0.001, 0.002}
    },
    anthropic: %{
      "claude-3-opus-20240229" => {0.015, 0.075},
      "claude-3-sonnet-20240229" => {0.003, 0.015},
      "claude-3-haiku-20240307" => {0.00025, 0.00125}
    },
    deepseek_r1: %{
      "deepseek-chat" => {0.001, 0.002},
      "deepseek-reasoner" => {0.001, 0.002}
    },
    ollama: %{
      # Free local models
      "_default" => {0.0, 0.0}
    }
  }

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a request with token usage.
  """
  @spec record_request(atom(), String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def record_request(provider, model, prompt_tokens, completion_tokens) do
    GenServer.cast(
      __MODULE__,
      {:record_request, provider, model, prompt_tokens, completion_tokens}
    )
  end

  @doc """
  Check if rate limits would be exceeded by a new request.

  Returns `:ok` if within limits, `{:error, reason}` if limit would be exceeded.
  """
  @spec check_rate_limit(atom()) :: :ok | {:error, atom()}
  def check_rate_limit(provider) do
    GenServer.call(__MODULE__, {:check_rate_limit, provider})
  end

  @doc """
  Get usage statistics for a provider or all providers.
  """
  @spec get_stats(atom()) :: map()
  def get_stats(provider \\ :all) do
    GenServer.call(__MODULE__, {:get_stats, provider})
  end

  @doc """
  Reset all usage statistics.
  """
  @spec reset_stats() :: :ok
  def reset_stats do
    GenServer.call(__MODULE__, :reset_stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@table_name, [:named_table, :public, :set])
    :ets.new(@window_table, [:named_table, :public, :bag])

    # Initialize stats for known providers
    for provider <- [:openai, :anthropic, :deepseek_r1, :ollama] do
      :ets.insert(
        @table_name,
        {provider,
         %{
           total_requests: 0,
           total_prompt_tokens: 0,
           total_completion_tokens: 0,
           total_tokens: 0,
           estimated_cost: 0.0,
           by_model: %{}
         }}
      )
    end

    # Schedule periodic cleanup of old window entries
    schedule_window_cleanup()

    Logger.info("AI Usage tracking started")

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record_request, provider, model, prompt_tokens, completion_tokens}, state) do
    now = System.system_time(:second)
    total_tokens = prompt_tokens + completion_tokens

    # Calculate cost
    cost = calculate_cost(provider, model, prompt_tokens, completion_tokens)

    # Update cumulative stats
    case :ets.lookup(@table_name, provider) do
      [{^provider, stats}] ->
        model_stats =
          Map.get(stats.by_model, model, %{
            requests: 0,
            prompt_tokens: 0,
            completion_tokens: 0,
            total_tokens: 0,
            cost: 0.0
          })

        updated_model_stats = %{
          requests: model_stats.requests + 1,
          prompt_tokens: model_stats.prompt_tokens + prompt_tokens,
          completion_tokens: model_stats.completion_tokens + completion_tokens,
          total_tokens: model_stats.total_tokens + total_tokens,
          cost: model_stats.cost + cost
        }

        updated_stats = %{
          total_requests: stats.total_requests + 1,
          total_prompt_tokens: stats.total_prompt_tokens + prompt_tokens,
          total_completion_tokens: stats.total_completion_tokens + completion_tokens,
          total_tokens: stats.total_tokens + total_tokens,
          estimated_cost: stats.estimated_cost + cost,
          by_model: Map.put(stats.by_model, model, updated_model_stats)
        }

        :ets.insert(@table_name, {provider, updated_stats})

      [] ->
        Logger.warning("Unknown provider: #{provider}")
    end

    # Add to time windows for rate limiting
    :ets.insert(@window_table, {provider, now, total_tokens})

    {:noreply, state}
  end

  @impl true
  def handle_call({:check_rate_limit, provider}, _from, state) do
    limits = get_limits()
    now = System.system_time(:second)

    # Check requests per minute
    minute_ago = now - 60
    minute_requests = count_requests_since(provider, minute_ago)

    if minute_requests >= limits.max_requests_per_minute do
      {:reply, {:error, :rate_limit_minute}, state}
    else
      # Check requests per hour
      hour_ago = now - 3_600
      hour_requests = count_requests_since(provider, hour_ago)

      if hour_requests >= limits.max_requests_per_hour do
        {:reply, {:error, :rate_limit_hour}, state}
      else
        # Check tokens per day
        day_ago = now - 86_400
        day_tokens = count_tokens_since(provider, day_ago)

        if day_tokens >= limits.max_tokens_per_day do
          {:reply, {:error, :rate_limit_day_tokens}, state}
        else
          {:reply, :ok, state}
        end
      end
    end
  end

  @impl true
  def handle_call({:get_stats, :all}, _from, state) do
    all_stats =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {provider, stats} -> {provider, stats} end)
      |> Map.new()

    {:reply, all_stats, state}
  end

  @impl true
  def handle_call({:get_stats, provider}, _from, state) do
    case :ets.lookup(@table_name, provider) do
      [{^provider, stats}] ->
        {:reply, stats, state}

      [] ->
        {:reply, %{}, state}
    end
  end

  @impl true
  def handle_call(:reset_stats, _from, state) do
    # Reset cumulative stats
    for provider <- [:openai, :anthropic, :deepseek_r1, :ollama] do
      :ets.insert(
        @table_name,
        {provider,
         %{
           total_requests: 0,
           total_prompt_tokens: 0,
           total_completion_tokens: 0,
           total_tokens: 0,
           estimated_cost: 0.0,
           by_model: %{}
         }}
      )
    end

    # Clear window entries
    :ets.delete_all_objects(@window_table)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup_windows, state) do
    cleanup_old_windows()
    schedule_window_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp get_limits do
    config = Application.get_env(:ragex, :ai_limits, [])

    %{
      max_requests_per_minute: Keyword.get(config, :max_requests_per_minute, 60),
      max_requests_per_hour: Keyword.get(config, :max_requests_per_hour, 1000),
      max_tokens_per_day: Keyword.get(config, :max_tokens_per_day, 100_000)
    }
  end

  defp calculate_cost(provider, model, prompt_tokens, completion_tokens) do
    provider_pricing = Map.get(@pricing, provider, %{})

    {input_price, output_price} =
      Map.get(provider_pricing, model, Map.get(provider_pricing, "_default", {0.0, 0.0}))

    # Price is per 1K tokens
    input_cost = prompt_tokens / 1000.0 * input_price
    output_cost = completion_tokens / 1000.0 * output_price

    Float.round(input_cost + output_cost, 6)
  end

  defp count_requests_since(provider, since_timestamp) do
    :ets.select(@window_table, [
      {{provider, :"$1", :_}, [{:>=, :"$1", since_timestamp}], [true]}
    ])
    |> length()
  end

  defp count_tokens_since(provider, since_timestamp) do
    :ets.select(@window_table, [
      {{provider, :"$1", :"$2"}, [{:>=, :"$1", since_timestamp}], [:"$2"]}
    ])
    |> Enum.sum()
  end

  defp cleanup_old_windows do
    # Remove entries older than 24 hours (no longer needed for rate limiting)
    day_ago = System.system_time(:second) - 86_400

    old_entries =
      :ets.select(@window_table, [
        {{:"$1", :"$2", :"$3"}, [{:<, :"$2", day_ago}], [:"$$"]}
      ])

    Enum.each(old_entries, fn [provider, timestamp, tokens] ->
      :ets.delete_object(@window_table, {provider, timestamp, tokens})
    end)

    if match?([_ | _], old_entries) do
      Logger.debug("Cleaned up #{length(old_entries)} old usage window entries")
    end
  end

  defp schedule_window_cleanup do
    # Clean up old windows every hour
    Process.send_after(self(), :cleanup_windows, 3_600_000)
  end
end
