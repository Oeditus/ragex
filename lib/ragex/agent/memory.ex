defmodule Ragex.Agent.Memory do
  @moduledoc """
  ETS-based conversation memory for agent sessions.

  Manages multi-turn conversations with:
  - Session lifecycle management
  - Message history with role tracking
  - Context window management (truncation)
  - Tool result storage
  - Automatic session expiration

  ## Usage

      # Create a new session
      {:ok, session} = Memory.new_session(%{project_path: "/path/to/project"})

      # Add messages
      :ok = Memory.add_message(session.id, :user, "Analyze this project")
      :ok = Memory.add_message(session.id, :assistant, "I'll analyze...")

      # Add tool result
      :ok = Memory.add_tool_result(session.id, "call_123", %{status: "success"})

      # Get conversation context for LLM
      {:ok, messages} = Memory.get_context(session.id, max_tokens: 4000)

      # End session
      :ok = Memory.clear_session(session.id)
  """

  use GenServer
  require Logger

  @table_name :ragex_agent_sessions
  @default_max_messages 100
  @default_context_max_chars 32_000
  @session_ttl_ms :timer.hours(24)
  @cleanup_interval_ms :timer.minutes(30)

  # Session struct
  defmodule Session do
    @moduledoc "Represents an agent conversation session."

    @type t :: %__MODULE__{
            id: String.t(),
            messages: [message()],
            metadata: map(),
            tool_results: map(),
            created_at: DateTime.t(),
            updated_at: DateTime.t()
          }

    @type message :: %{
            role: :system | :user | :assistant | :tool,
            content: String.t(),
            name: String.t() | nil,
            tool_call_id: String.t() | nil,
            tool_calls: [map()] | nil,
            timestamp: DateTime.t()
          }

    defstruct [
      :id,
      :messages,
      :metadata,
      :tool_results,
      :created_at,
      :updated_at
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new conversation session.

  ## Parameters

  - `metadata` - Optional metadata map (e.g., project_path, issues)

  ## Returns

  - `{:ok, session}` - New session struct
  """
  @spec new_session(map()) :: {:ok, Session.t()}
  def new_session(metadata \\ %{}) do
    GenServer.call(__MODULE__, {:new_session, metadata})
  end

  @doc """
  Get a session by ID.

  ## Returns

  - `{:ok, session}` - Session found
  - `{:error, :not_found}` - Session doesn't exist or expired
  """
  @spec get_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(session_id) do
    GenServer.call(__MODULE__, {:get_session, session_id})
  end

  @doc """
  Check if a session exists and is active.
  """
  @spec session_exists?(String.t()) :: boolean()
  def session_exists?(session_id) do
    case get_session(session_id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Add a message to a session.

  ## Parameters

  - `session_id` - Session ID
  - `role` - Message role: :system, :user, :assistant, or :tool
  - `content` - Message content
  - `opts` - Optional:
    - `:name` - Function name for tool messages
    - `:tool_call_id` - Tool call ID for tool response messages
    - `:tool_calls` - Tool calls made by assistant

  ## Returns

  - `:ok` - Message added
  - `{:error, :not_found}` - Session not found
  """
  @spec add_message(String.t(), atom(), String.t(), keyword()) ::
          :ok | {:error, :not_found}
  def add_message(session_id, role, content, opts \\ []) do
    GenServer.call(__MODULE__, {:add_message, session_id, role, content, opts})
  end

  @doc """
  Add a tool result to the session.

  Tool results are stored separately and can be referenced by tool_call_id.
  """
  @spec add_tool_result(String.t(), String.t(), any()) :: :ok | {:error, :not_found}
  def add_tool_result(session_id, tool_call_id, result) do
    GenServer.call(__MODULE__, {:add_tool_result, session_id, tool_call_id, result})
  end

  @doc """
  Get all messages from a session.

  ## Options

  - `:limit` - Maximum number of messages to return (most recent)
  """
  @spec get_messages(String.t(), keyword()) :: {:ok, [map()]} | {:error, :not_found}
  def get_messages(session_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_messages, session_id, opts})
  end

  @doc """
  Get conversation context suitable for LLM consumption.

  Applies truncation to fit within context window limits.

  ## Options

  - `:max_chars` - Maximum total characters (default: 32,000)
  - `:include_system` - Include system messages (default: true)
  - `:format` - Output format: :openai (default) or :anthropic
  """
  @spec get_context(String.t(), keyword()) :: {:ok, [map()]} | {:error, :not_found}
  def get_context(session_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_context, session_id, opts})
  end

  @doc """
  Update session metadata.
  """
  @spec update_metadata(String.t(), map()) :: :ok | {:error, :not_found}
  def update_metadata(session_id, metadata) do
    GenServer.call(__MODULE__, {:update_metadata, session_id, metadata})
  end

  @doc """
  Clear/delete a session.
  """
  @spec clear_session(String.t()) :: :ok
  def clear_session(session_id) do
    GenServer.call(__MODULE__, {:clear_session, session_id})
  end

  @doc """
  List all active sessions.

  ## Options

  - `:limit` - Maximum number of sessions to return
  """
  @spec list_sessions(keyword()) :: [Session.t()]
  def list_sessions(opts \\ []) do
    GenServer.call(__MODULE__, {:list_sessions, opts})
  end

  @doc """
  Get session statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table if it doesn't exist
    table =
      case :ets.whereis(@table_name) do
        :undefined ->
          :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

        tid ->
          tid
      end

    # Schedule cleanup
    schedule_cleanup()

    Logger.info("Agent Memory started")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:new_session, metadata}, _from, state) do
    now = DateTime.utc_now()

    session = %Session{
      id: generate_session_id(),
      messages: [],
      metadata: metadata,
      tool_results: %{},
      created_at: now,
      updated_at: now
    }

    :ets.insert(@table_name, {session.id, session})
    Logger.debug("Created new agent session: #{session.id}")
    {:reply, {:ok, session}, state}
  end

  @impl true
  def handle_call({:get_session, session_id}, _from, state) do
    result =
      case :ets.lookup(@table_name, session_id) do
        [{^session_id, session}] ->
          if session_expired?(session) do
            :ets.delete(@table_name, session_id)
            {:error, :not_found}
          else
            {:ok, session}
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:add_message, session_id, role, content, opts}, _from, state) do
    result =
      with {:ok, session} <- lookup_session(session_id) do
        message = build_message(role, content, opts)
        updated_messages = truncate_messages(session.messages ++ [message])

        updated_session = %{
          session
          | messages: updated_messages,
            updated_at: DateTime.utc_now()
        }

        :ets.insert(@table_name, {session_id, updated_session})
        :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:add_tool_result, session_id, tool_call_id, result}, _from, state) do
    reply =
      with {:ok, session} <- lookup_session(session_id) do
        updated_results = Map.put(session.tool_results, tool_call_id, result)

        updated_session = %{
          session
          | tool_results: updated_results,
            updated_at: DateTime.utc_now()
        }

        :ets.insert(@table_name, {session_id, updated_session})
        :ok
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_messages, session_id, opts}, _from, state) do
    result =
      with {:ok, session} <- lookup_session(session_id) do
        limit = Keyword.get(opts, :limit)

        messages =
          if limit do
            Enum.take(session.messages, -limit)
          else
            session.messages
          end

        {:ok, messages}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_context, session_id, opts}, _from, state) do
    result =
      with {:ok, session} <- lookup_session(session_id) do
        max_chars = Keyword.get(opts, :max_chars, @default_context_max_chars)
        include_system = Keyword.get(opts, :include_system, true)
        format = Keyword.get(opts, :format, :openai)

        messages =
          session.messages
          |> maybe_filter_system(include_system)
          |> truncate_for_context(max_chars)
          |> format_for_provider(format)

        {:ok, messages}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:update_metadata, session_id, metadata}, _from, state) do
    result =
      with {:ok, session} <- lookup_session(session_id) do
        updated_session = %{
          session
          | metadata: Map.merge(session.metadata, metadata),
            updated_at: DateTime.utc_now()
        }

        :ets.insert(@table_name, {session_id, updated_session})
        :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:clear_session, session_id}, _from, state) do
    :ets.delete(@table_name, session_id)
    Logger.debug("Cleared agent session: #{session_id}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:list_sessions, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)

    sessions =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_id, session} -> session end)
      |> Enum.reject(&session_expired?/1)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.take(limit)

    {:reply, sessions, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    all_sessions = :ets.tab2list(@table_name)
    active_sessions = Enum.reject(all_sessions, fn {_, s} -> session_expired?(s) end)

    stats = %{
      total_sessions: length(active_sessions),
      total_messages:
        active_sessions
        |> Enum.map(fn {_, s} -> length(s.messages) end)
        |> Enum.sum(),
      oldest_session:
        case active_sessions do
          [] -> nil
          sessions -> sessions |> Enum.min_by(fn {_, s} -> s.created_at end) |> elem(1)
        end,
      memory_bytes: :ets.info(@table_name, :memory) * :erlang.system_info(:wordsize)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_sessions()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp lookup_session(session_id) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, session}] ->
        if session_expired?(session) do
          :ets.delete(@table_name, session_id)
          {:error, :not_found}
        else
          {:ok, session}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp build_message(role, content, opts) do
    %{
      role: role,
      content: content,
      name: Keyword.get(opts, :name),
      tool_call_id: Keyword.get(opts, :tool_call_id),
      tool_calls: Keyword.get(opts, :tool_calls),
      timestamp: DateTime.utc_now()
    }
  end

  defp truncate_messages(messages) when length(messages) > @default_max_messages do
    # Keep system messages and most recent others
    {system_msgs, other_msgs} = Enum.split_with(messages, &(&1.role == :system))
    keep_count = @default_max_messages - length(system_msgs)
    system_msgs ++ Enum.take(other_msgs, -keep_count)
  end

  defp truncate_messages(messages), do: messages

  defp maybe_filter_system(messages, true), do: messages

  defp maybe_filter_system(messages, false) do
    Enum.reject(messages, &(&1.role == :system))
  end

  defp truncate_for_context(messages, max_chars) do
    # Start from most recent, work backwards
    {kept, _} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn msg, {acc, total_chars} ->
        msg_chars = String.length(msg.content || "")

        if total_chars + msg_chars <= max_chars do
          {:cont, {[msg | acc], total_chars + msg_chars}}
        else
          # Try to include system messages even if over limit
          if msg.role == :system do
            {:cont, {[msg | acc], total_chars + msg_chars}}
          else
            {:halt, {acc, total_chars}}
          end
        end
      end)

    kept
  end

  defp format_for_provider(messages, :openai) do
    Enum.map(messages, fn msg ->
      base = %{
        role: to_string(msg.role),
        content: msg.content
      }

      base
      |> maybe_add(:name, msg.name)
      |> maybe_add(:tool_call_id, msg.tool_call_id)
      |> maybe_add(:tool_calls, format_tool_calls(msg.tool_calls))
    end)
  end

  defp format_for_provider(messages, :anthropic) do
    # Anthropic uses different message format
    # System messages are passed separately, not in messages array
    messages
    |> Enum.reject(&(&1.role == :system))
    |> Enum.map(fn msg ->
      role =
        case msg.role do
          :assistant -> "assistant"
          :tool -> "user"
          _ -> "user"
        end

      content =
        if msg.role == :tool do
          # Anthropic tool results are structured differently
          [
            %{
              type: "tool_result",
              tool_use_id: msg.tool_call_id,
              content: msg.content
            }
          ]
        else
          msg.content
        end

      %{role: role, content: content}
    end)
  end

  defp format_for_provider(messages, _), do: format_for_provider(messages, :openai)

  defp format_tool_calls(nil), do: nil

  defp format_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        id: tc.id,
        type: "function",
        function: %{
          name: tc.name,
          arguments: Jason.encode!(tc.arguments)
        }
      }
    end)
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp session_expired?(%Session{updated_at: updated_at}) do
    diff_ms = DateTime.diff(DateTime.utc_now(), updated_at, :millisecond)
    diff_ms > @session_ttl_ms
  end

  defp cleanup_expired_sessions do
    :ets.tab2list(@table_name)
    |> Enum.filter(fn {_, session} -> session_expired?(session) end)
    |> Enum.each(fn {id, _} ->
      :ets.delete(@table_name, id)
      Logger.debug("Cleaned up expired session: #{id}")
    end)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
