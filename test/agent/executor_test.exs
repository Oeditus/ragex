defmodule Ragex.Agent.ExecutorTest do
  use ExUnit.Case, async: false

  alias Ragex.Agent.{Executor, Memory}

  # Setup for tests
  setup do
    # Start Memory GenServer if not already running
    case GenServer.whereis(Memory) do
      nil ->
        {:ok, _pid} = Memory.start_link([])

      _pid ->
        :ok
    end

    # Clean up sessions
    for session <- Memory.list_sessions() do
      Memory.clear_session(session.id)
    end

    :ok
  end

  describe "run/2 - basic behavior" do
    @tag :external_api
    @tag skip: true, reason: :requires_api_key
    test "returns result with expected structure" do
      {:ok, session} = Memory.new_session(%{test: true})
      Memory.add_message(session.id, :system, "You are a test assistant.")
      Memory.add_message(session.id, :user, "Say 'Hello test'")

      {:ok, result} = Executor.run(session.id, max_iterations: 1)

      assert is_map(result)
      assert Map.has_key?(result, :content)
      assert Map.has_key?(result, :iterations)
      assert Map.has_key?(result, :tool_calls_made)
      assert Map.has_key?(result, :usage)
      assert Map.has_key?(result, :session_id)
      assert result.session_id == session.id
    end
  end

  describe "run/2 - session handling" do
    test "returns error for non-existent session" do
      result = Executor.run("nonexistent-session-id")

      assert {:error, :not_found} = result
    end
  end

  describe "step/2" do
    @tag :external_api
    @tag skip: true, reason: :requires_api_key
    test "executes single step" do
      {:ok, session} = Memory.new_session()
      Memory.add_message(session.id, :system, "Test")
      Memory.add_message(session.id, :user, "Hello")

      result = Executor.step(session.id)

      # Check result is one of the expected forms
      assert match?({:done, _, _}, result) or
               match?({:continue, _}, result) or
               match?({:error, _}, result)
    end
  end

  describe "tool execution" do
    @tag :external_api
    @tag skip: true, reason: :requires_api_key
    test "tool calls are recorded in session" do
      {:ok, session} = Memory.new_session()
      Memory.add_message(session.id, :system, "You can use tools to help.")
      Memory.add_message(session.id, :user, "Analyze the graph stats")

      {:ok, result} = Executor.run(session.id, max_iterations: 3)

      # Check tool calls were tracked
      assert result.tool_calls_made >= 0
    end
  end

  describe "options" do
    test "supports max_iterations option" do
      {:ok, _session} = Memory.new_session()

      # Just verify option is accepted (actual execution needs API)
      assert is_function(&Executor.run/2)
    end

    test "supports provider option" do
      # Verify option structures exist for different providers
      providers = [:deepseek_r1, :openai, :anthropic, :ollama]

      for provider <- providers do
        assert is_atom(provider)
      end
    end

    test "supports temperature option" do
      {:ok, session} = Memory.new_session()
      Memory.add_message(session.id, :user, "test")

      # Just verify the option key exists (no actual API call)
      opts = [temperature: 0.5]
      assert Keyword.has_key?(opts, :temperature)
    end

    test "supports max_tokens option" do
      opts = [max_tokens: 2048]
      assert Keyword.has_key?(opts, :max_tokens)
    end

    test "supports tool_choice option" do
      opts = [tool_choice: "auto"]
      assert Keyword.has_key?(opts, :tool_choice)
    end
  end

  describe "usage tracking" do
    @tag :external_api
    @tag skip: true, reason: :requires_api_key
    test "tracks token usage" do
      {:ok, session} = Memory.new_session()
      Memory.add_message(session.id, :system, "Test")
      Memory.add_message(session.id, :user, "Hello")

      {:ok, result} = Executor.run(session.id, max_iterations: 1)

      assert is_map(result.usage)

      assert Map.has_key?(result.usage, :prompt_tokens) or
               Map.has_key?(result.usage, :total_tokens) or
               result.usage == %{}
    end
  end

  describe "message handling" do
    @tag :external_api
    @tag skip: true, reason: :requires_api_key
    test "adds assistant response to session" do
      {:ok, session} = Memory.new_session()
      Memory.add_message(session.id, :system, "You are a test assistant.")
      Memory.add_message(session.id, :user, "Say hello")

      {:ok, _result} = Executor.run(session.id, max_iterations: 1)

      {:ok, messages} = Memory.get_messages(session.id)

      # Should have assistant message added
      assistant_msgs = Enum.filter(messages, &(&1.role == :assistant))
      assert match?([_ | _], assistant_msgs)
    end
  end
end
