defmodule Ragex.Agent.MemoryTest do
  use ExUnit.Case, async: false

  alias Ragex.Agent.Memory
  alias Ragex.Agent.Memory.Session

  # Ensure Memory GenServer is started
  setup do
    # Start Memory GenServer if not already running
    case GenServer.whereis(Memory) do
      nil ->
        {:ok, _pid} = Memory.start_link([])

      _pid ->
        :ok
    end

    # Clean up any stale sessions from previous tests
    existing_sessions = Memory.list_sessions()

    for session <- existing_sessions do
      Memory.clear_session(session.id)
    end

    :ok
  end

  describe "new_session/1" do
    test "creates a session with empty metadata" do
      {:ok, session} = Memory.new_session()

      assert %Session{} = session
      assert is_binary(session.id)
      assert session.messages == []
      assert session.metadata == %{}
      assert session.tool_results == %{}
      assert %DateTime{} = session.created_at
      assert %DateTime{} = session.updated_at
    end

    test "creates a session with metadata" do
      metadata = %{project_path: "/some/path", custom: "value"}
      {:ok, session} = Memory.new_session(metadata)

      assert session.metadata == metadata
    end

    test "generates unique session IDs" do
      {:ok, session1} = Memory.new_session()
      {:ok, session2} = Memory.new_session()

      refute session1.id == session2.id
    end
  end

  describe "get_session/1" do
    test "returns existing session" do
      {:ok, created} = Memory.new_session(%{test: true})

      {:ok, retrieved} = Memory.get_session(created.id)

      assert retrieved.id == created.id
      assert retrieved.metadata == %{test: true}
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = Memory.get_session("nonexistent-id")
    end
  end

  describe "session_exists?/1" do
    test "returns true for existing session" do
      {:ok, session} = Memory.new_session()

      assert Memory.session_exists?(session.id)
    end

    test "returns false for non-existent session" do
      refute Memory.session_exists?("nonexistent-id")
    end
  end

  describe "add_message/4" do
    test "adds user message to session" do
      {:ok, session} = Memory.new_session()

      :ok = Memory.add_message(session.id, :user, "Hello!")

      {:ok, messages} = Memory.get_messages(session.id)
      assert [msg] = messages
      assert msg.role == :user
      assert msg.content == "Hello!"
      assert %DateTime{} = msg.timestamp
    end

    test "adds assistant message to session" do
      {:ok, session} = Memory.new_session()

      :ok = Memory.add_message(session.id, :assistant, "Hi there!")

      {:ok, messages} = Memory.get_messages(session.id)
      assert [msg] = messages
      assert msg.role == :assistant
    end

    test "adds system message to session" do
      {:ok, session} = Memory.new_session()

      :ok = Memory.add_message(session.id, :system, "You are a helpful assistant.")

      {:ok, messages} = Memory.get_messages(session.id)
      assert [msg] = messages
      assert msg.role == :system
    end

    test "adds tool message with options" do
      {:ok, session} = Memory.new_session()

      :ok =
        Memory.add_message(session.id, :tool, "Result data",
          tool_call_id: "call_123",
          name: "analyze_file"
        )

      {:ok, messages} = Memory.get_messages(session.id)
      assert [msg] = messages
      assert msg.role == :tool
      assert msg.tool_call_id == "call_123"
      assert msg.name == "analyze_file"
    end

    test "adds assistant message with tool_calls" do
      {:ok, session} = Memory.new_session()

      tool_calls = [
        %{id: "call_1", name: "analyze_file", arguments: %{path: "/test"}}
      ]

      :ok = Memory.add_message(session.id, :assistant, "Analyzing...", tool_calls: tool_calls)

      {:ok, messages} = Memory.get_messages(session.id)
      assert [msg] = messages
      assert msg.tool_calls == tool_calls
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = Memory.add_message("nonexistent", :user, "Hello")
    end

    test "preserves message order" do
      {:ok, session} = Memory.new_session()

      :ok = Memory.add_message(session.id, :user, "First")
      :ok = Memory.add_message(session.id, :assistant, "Second")
      :ok = Memory.add_message(session.id, :user, "Third")

      {:ok, messages} = Memory.get_messages(session.id)
      assert [first, second, third] = messages
      assert first.content == "First"
      assert second.content == "Second"
      assert third.content == "Third"
    end
  end

  describe "add_tool_result/3" do
    test "stores tool result" do
      {:ok, session} = Memory.new_session()

      result = %{status: "success", data: [1, 2, 3]}
      :ok = Memory.add_tool_result(session.id, "call_123", result)

      {:ok, updated_session} = Memory.get_session(session.id)
      assert updated_session.tool_results["call_123"] == result
    end

    test "updates session timestamp" do
      {:ok, session} = Memory.new_session()
      original_updated = session.updated_at

      # Small delay to ensure timestamp difference
      Process.sleep(10)

      :ok = Memory.add_tool_result(session.id, "call_123", %{})

      {:ok, updated_session} = Memory.get_session(session.id)
      assert DateTime.compare(updated_session.updated_at, original_updated) == :gt
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = Memory.add_tool_result("nonexistent", "call_1", %{})
    end
  end

  describe "get_messages/2" do
    test "returns all messages" do
      {:ok, session} = Memory.new_session()
      :ok = Memory.add_message(session.id, :user, "One")
      :ok = Memory.add_message(session.id, :assistant, "Two")
      :ok = Memory.add_message(session.id, :user, "Three")

      {:ok, messages} = Memory.get_messages(session.id)

      assert [_, _, _] = messages
    end

    test "respects limit option" do
      {:ok, session} = Memory.new_session()
      :ok = Memory.add_message(session.id, :user, "One")
      :ok = Memory.add_message(session.id, :assistant, "Two")
      :ok = Memory.add_message(session.id, :user, "Three")

      {:ok, messages} = Memory.get_messages(session.id, limit: 2)

      # Should return most recent 2
      assert [_, _] = messages
      assert List.last(messages).content == "Three"
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = Memory.get_messages("nonexistent")
    end
  end

  describe "get_context/2" do
    test "returns messages in OpenAI format by default" do
      {:ok, session} = Memory.new_session()
      :ok = Memory.add_message(session.id, :system, "System prompt")
      :ok = Memory.add_message(session.id, :user, "Hello")
      :ok = Memory.add_message(session.id, :assistant, "Hi!")

      {:ok, context} = Memory.get_context(session.id)

      assert is_list(context)

      for msg <- context do
        assert Map.has_key?(msg, :role)
        assert Map.has_key?(msg, :content)
        assert is_binary(msg.role)
      end
    end

    test "formats for Anthropic provider" do
      {:ok, session} = Memory.new_session()
      :ok = Memory.add_message(session.id, :system, "System prompt")
      :ok = Memory.add_message(session.id, :user, "Hello")
      :ok = Memory.add_message(session.id, :assistant, "Hi!")

      {:ok, context} = Memory.get_context(session.id, format: :anthropic)

      # Anthropic format excludes system messages from messages array
      assert is_list(context)
      # System message should be excluded
      refute Enum.any?(context, fn msg -> msg[:role] == "system" end)
    end

    test "respects max_chars truncation" do
      {:ok, session} = Memory.new_session()
      :ok = Memory.add_message(session.id, :user, String.duplicate("a", 5000))
      :ok = Memory.add_message(session.id, :assistant, String.duplicate("b", 5000))
      :ok = Memory.add_message(session.id, :user, String.duplicate("c", 5000))

      {:ok, context} = Memory.get_context(session.id, max_chars: 6000)

      # Should truncate from beginning, keeping most recent
      total_chars =
        Enum.reduce(context, 0, fn msg, acc ->
          acc + String.length(msg.content || "")
        end)

      # Most recent messages should be kept
      assert length(context) < 3 or total_chars <= 6000
    end

    test "can exclude system messages" do
      {:ok, session} = Memory.new_session()
      :ok = Memory.add_message(session.id, :system, "System prompt")
      :ok = Memory.add_message(session.id, :user, "Hello")

      {:ok, context} = Memory.get_context(session.id, include_system: false)

      refute Enum.any?(context, fn msg -> msg.role == "system" end)
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = Memory.get_context("nonexistent")
    end
  end

  describe "update_metadata/2" do
    test "merges new metadata" do
      {:ok, session} = Memory.new_session(%{initial: "value"})

      :ok = Memory.update_metadata(session.id, %{new: "data"})

      {:ok, updated} = Memory.get_session(session.id)
      assert updated.metadata == %{initial: "value", new: "data"}
    end

    test "overwrites existing keys" do
      {:ok, session} = Memory.new_session(%{key: "original"})

      :ok = Memory.update_metadata(session.id, %{key: "updated"})

      {:ok, updated} = Memory.get_session(session.id)
      assert updated.metadata.key == "updated"
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = Memory.update_metadata("nonexistent", %{})
    end
  end

  describe "clear_session/1" do
    test "removes session" do
      {:ok, session} = Memory.new_session()
      assert Memory.session_exists?(session.id)

      :ok = Memory.clear_session(session.id)

      refute Memory.session_exists?(session.id)
    end

    test "returns ok for non-existent session" do
      assert :ok = Memory.clear_session("nonexistent")
    end
  end

  describe "list_sessions/1" do
    test "returns empty list when no sessions" do
      sessions = Memory.list_sessions()

      assert is_list(sessions)
    end

    test "returns all active sessions" do
      {:ok, _session1} = Memory.new_session(%{name: "one"})
      {:ok, _session2} = Memory.new_session(%{name: "two"})

      sessions = Memory.list_sessions()

      assert length(sessions) >= 2
    end

    test "respects limit option" do
      {:ok, _} = Memory.new_session()
      {:ok, _} = Memory.new_session()
      {:ok, _} = Memory.new_session()

      sessions = Memory.list_sessions(limit: 2)

      assert length(sessions) <= 2
    end

    test "orders by updated_at descending" do
      {:ok, _session1} = Memory.new_session()
      Process.sleep(10)
      {:ok, _session2} = Memory.new_session()
      Process.sleep(10)
      {:ok, session3} = Memory.new_session()

      sessions = Memory.list_sessions(limit: 3)

      ids = Enum.map(sessions, & &1.id)
      # Most recent first
      assert List.first(ids) == session3.id
    end
  end

  describe "stats/0" do
    test "returns session statistics" do
      {:ok, session} = Memory.new_session()
      :ok = Memory.add_message(session.id, :user, "Hello")
      :ok = Memory.add_message(session.id, :assistant, "Hi!")

      stats = Memory.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_sessions)
      assert Map.has_key?(stats, :total_messages)
      assert Map.has_key?(stats, :memory_bytes)
      assert stats.total_sessions >= 1
      assert stats.total_messages >= 2
    end
  end

  describe "message truncation" do
    test "truncates when exceeding max messages" do
      {:ok, session} = Memory.new_session()

      # Add more than the default max (100)
      for i <- 1..105 do
        :ok = Memory.add_message(session.id, :user, "Message #{i}")
      end

      {:ok, messages} = Memory.get_messages(session.id)

      # Should be truncated to max
      assert length(messages) <= 100
    end

    test "preserves system messages during truncation" do
      {:ok, session} = Memory.new_session()

      # Add system message first
      :ok = Memory.add_message(session.id, :system, "System prompt")

      # Add many user messages
      for i <- 1..105 do
        :ok = Memory.add_message(session.id, :user, "Message #{i}")
      end

      {:ok, messages} = Memory.get_messages(session.id)

      # System message should still be present
      assert Enum.any?(messages, fn m -> m.role == :system end)
    end
  end
end
