defmodule Ragex.Agent.MemoryPersistenceTest do
  use ExUnit.Case, async: false

  alias Ragex.Agent.Memory

  @tmp_dir System.tmp_dir!() |> Path.join("ragex_session_test_#{:os.getpid()}")

  setup do
    # Point persistence at a temp dir for each test
    Application.put_env(:ragex, :session_persistence_dir, @tmp_dir)
    File.mkdir_p!(@tmp_dir)

    # Start fresh — clear ETS and temp files
    clear_ets_and_files()

    on_exit(fn ->
      Application.delete_env(:ragex, :session_persistence_dir)
      File.rm_rf!(@tmp_dir)
    end)

    :ok
  end

  describe "persist_session / restore_sessions_from_disk" do
    test "a new session is written to disk" do
      {:ok, session} = Memory.new_session(%{test: true})

      expected_path =
        Path.join(@tmp_dir, session.id <> ".session")

      assert File.exists?(expected_path)
    end

    test "session file is valid BEAM term" do
      {:ok, session} = Memory.new_session(%{})
      path = Path.join(@tmp_dir, session.id <> ".session")
      binary = File.read!(path)
      decoded = :erlang.binary_to_term(binary, [:safe])

      assert decoded.id == session.id
    end

    test "adding a message updates the session file" do
      {:ok, session} = Memory.new_session(%{})
      :ok = Memory.add_message(session.id, :user, "hello")

      path = Path.join(@tmp_dir, session.id <> ".session")
      binary = File.read!(path)
      decoded = :erlang.binary_to_term(binary, [:safe])

      assert length(decoded.messages) == 1
      assert hd(decoded.messages).content == "hello"
    end

    test "clearing a session removes the file" do
      {:ok, session} = Memory.new_session(%{})
      path = Path.join(@tmp_dir, session.id <> ".session")
      assert File.exists?(path)

      Memory.clear_session(session.id)
      refute File.exists?(path)
    end
  end

  describe "persist_all/0" do
    test "returns {:ok, count} when persistence is enabled" do
      {:ok, _s1} = Memory.new_session(%{tag: "a"})
      {:ok, _s2} = Memory.new_session(%{tag: "b"})

      # persist_all is a no-op because sessions were already written,
      # but the count should match the active session total
      {:ok, count} = Memory.persist_all()
      assert count >= 2
    end

    test "returns {:error, :persistence_disabled} when dir not configured" do
      Application.delete_env(:ragex, :session_persistence_dir)

      assert {:error, :persistence_disabled} = Memory.persist_all()
    after
      Application.put_env(:ragex, :session_persistence_dir, @tmp_dir)
    end
  end

  describe "session restoration on Memory restart" do
    test "sessions written to disk are loadable via restore logic" do
      {:ok, session} = Memory.new_session(%{persisted: true})
      :ok = Memory.add_message(session.id, :user, "restore me")

      path = Path.join(@tmp_dir, session.id <> ".session")
      binary = File.read!(path)

      # Simulate loading into a fresh ETS table
      :ets.delete_all_objects(:ragex_agent_sessions)
      session_restored = :erlang.binary_to_term(binary, [:safe])
      :ets.insert(:ragex_agent_sessions, {session_restored.id, session_restored})

      assert {:ok, loaded} = Memory.get_session(session.id)
      assert loaded.metadata.persisted == true
      assert length(loaded.messages) == 1
    end
  end

  describe "persistence_dir/0" do
    test "returns the configured path" do
      assert Memory.persistence_dir() == @tmp_dir
    end

    test "returns nil when not configured" do
      Application.delete_env(:ragex, :session_persistence_dir)
      assert Memory.persistence_dir() == nil
    after
      Application.put_env(:ragex, :session_persistence_dir, @tmp_dir)
    end
  end

  describe "no-op when persistence not configured" do
    test "new_session succeeds in ETS-only mode" do
      Application.delete_env(:ragex, :session_persistence_dir)

      {:ok, session} = Memory.new_session(%{})
      assert {:ok, _} = Memory.get_session(session.id)

      # No file created
      files = File.ls!(@tmp_dir)
      assert Enum.empty?(files)
    after
      Application.put_env(:ragex, :session_persistence_dir, @tmp_dir)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp clear_ets_and_files do
    # Clear ETS if the table exists (Memory GenServer may already be running)
    if :ets.whereis(:ragex_agent_sessions) != :undefined do
      :ets.delete_all_objects(:ragex_agent_sessions)
    end

    # Remove any leftover session files from a prior test
    case File.ls(@tmp_dir) do
      {:ok, files} ->
        Enum.each(files, fn f ->
          if String.ends_with?(f, ".session") do
            File.rm(Path.join(@tmp_dir, f))
          end
        end)

      _ ->
        :ok
    end
  end
end
