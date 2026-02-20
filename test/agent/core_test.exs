defmodule Ragex.Agent.CoreTest do
  use ExUnit.Case, async: false

  alias Ragex.Agent.{Core, Memory}

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

  describe "analyze_project/2 - path validation" do
    test "returns error for non-existent path" do
      result = Core.analyze_project("/nonexistent/path/that/does/not/exist")

      assert {:error, {:path_not_found, _}} = result
    end

    test "returns error for file path (not directory)" do
      # Create a temp file
      tmp_file = Path.join(System.tmp_dir!(), "ragex_test_file_#{:rand.uniform(10000)}.txt")
      File.write!(tmp_file, "test content")

      on_exit(fn -> File.rm(tmp_file) end)

      result = Core.analyze_project(tmp_file)

      assert {:error, {:not_a_directory, _}} = result
    end
  end

  describe "analyze_project/2 - full analysis" do
    @tag :slow
    @tag skip: true, reason: :requires_api_key
    test "analyzes directory and returns result" do
      # Use a small test directory
      tmp_dir = Path.join(System.tmp_dir!(), "ragex_test_proj_#{:rand.uniform(10000)}")
      File.mkdir_p!(tmp_dir)

      File.write!(
        Path.join(tmp_dir, "test.ex"),
        "defmodule Test do\n  def hello, do: :world\nend\n"
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, result} = Core.analyze_project(tmp_dir)

      assert is_map(result)
      assert Map.has_key?(result, :session_id)
      assert Map.has_key?(result, :report)
      assert Map.has_key?(result, :issues)
      assert Map.has_key?(result, :summary)
      assert is_binary(result.report)
      assert is_map(result.summary)
    end
  end

  describe "quick_analyze/2" do
    @tag skip: true, reason: :requires_full_app
    test "analyzes without AI polishing" do
      # This test requires full app infrastructure (FileTracker ETS, Graph Store, etc.)
      # Run with `mix test` (not --no-start) to execute this test
      project_path = "/opt/Proyectos/Oeditus/ragex/lib/ragex/agent"

      if File.dir?(project_path) do
        {:ok, result} = Core.quick_analyze(project_path, skip_embeddings: true)

        assert is_map(result)
        assert Map.has_key?(result, :issues)
        assert Map.has_key?(result, :summary)
        assert is_map(result.summary)
        assert Map.has_key?(result.summary, :total_issues)
      end
    end

    test "returns error for invalid path" do
      result = Core.quick_analyze("/nonexistent/path")

      assert {:error, {:path_not_found, _}} = result
    end
  end

  describe "chat/3" do
    test "returns error for non-existent session" do
      result = Core.chat("nonexistent-session", "Hello")

      assert {:error, :not_found} = result
    end

    @tag :external_api
    @tag skip: true, reason: :requires_api_key
    test "continues conversation in session" do
      {:ok, session} = Memory.new_session(%{project_path: "/test"})
      Memory.add_message(session.id, :system, "You are a test assistant.")

      {:ok, result} = Core.chat(session.id, "Hello, assistant!")

      assert is_map(result)
      assert Map.has_key?(result, :content)
      assert is_binary(result.content)
    end
  end

  describe "get_report/2" do
    test "returns error for non-existent session" do
      result = Core.get_report("nonexistent-session")

      assert {:error, :not_found} = result
    end

    test "returns existing report from metadata" do
      {:ok, session} = Memory.new_session(%{report: "Test Report Content"})

      {:ok, report} = Core.get_report(session.id)

      assert report == "Test Report Content"
    end

    @tag :external_api
    @tag skip: true, reason: :requires_api_key
    test "generates report on-demand if not cached" do
      issues = %{dead_code: [%{file: "test.ex", name: "unused", line: 1}]}
      {:ok, session} = Memory.new_session(%{issues: issues})

      {:ok, report} = Core.get_report(session.id)

      assert is_binary(report)
    end
  end

  describe "list_sessions/1" do
    test "returns empty list when no sessions" do
      sessions = Core.list_sessions()

      assert is_list(sessions)
    end

    test "returns formatted session list" do
      {:ok, _session1} = Memory.new_session(%{project_path: "/path1"})
      {:ok, _session2} = Memory.new_session(%{project_path: "/path2"})

      sessions = Core.list_sessions()

      assert length(sessions) >= 2

      for session <- sessions do
        assert Map.has_key?(session, :id)
        assert Map.has_key?(session, :project_path)
        assert Map.has_key?(session, :created_at)
        assert Map.has_key?(session, :message_count)
      end
    end

    test "respects limit option" do
      {:ok, _} = Memory.new_session()
      {:ok, _} = Memory.new_session()
      {:ok, _} = Memory.new_session()

      sessions = Core.list_sessions(limit: 2)

      assert length(sessions) <= 2
    end
  end

  describe "get_session/1" do
    test "returns error for non-existent session" do
      result = Core.get_session("nonexistent")

      assert {:error, :not_found} = result
    end

    test "returns formatted session details" do
      issues = %{dead_code: [%{}, %{}], security: [%{}]}
      {:ok, created} = Memory.new_session(%{project_path: "/test/path", issues: issues})
      Memory.add_message(created.id, :user, "Hello")
      Memory.add_message(created.id, :assistant, "Hi")

      {:ok, session} = Core.get_session(created.id)

      assert session.id == created.id
      assert session.project_path == "/test/path"
      assert session.message_count == 2
      assert is_boolean(session.has_report)
      assert is_map(session.issues_summary)
      assert session.issues_summary.dead_code_count == 2
      assert session.issues_summary.security_count == 1
    end
  end

  describe "clear_session/1" do
    test "removes session" do
      {:ok, session} = Memory.new_session()
      assert Memory.session_exists?(session.id)

      :ok = Core.clear_session(session.id)

      refute Memory.session_exists?(session.id)
    end

    test "returns ok for non-existent session" do
      assert :ok = Core.clear_session("nonexistent")
    end
  end

  describe "issue counting" do
    test "counts issues correctly in summary" do
      issues = %{
        dead_code: [%{}, %{}, %{}],
        duplicates: [%{}, %{}],
        security: [%{}],
        smells: [],
        complexity: nil,
        circular_deps: %{items: [%{}, %{}]},
        suggestions: %{count: 5}
      }

      {:ok, session} = Memory.new_session(%{issues: issues})
      {:ok, details} = Core.get_session(session.id)

      summary = details.issues_summary

      assert summary.dead_code_count == 3
      assert summary.duplicate_count == 2
      assert summary.security_count == 1
      assert summary.smell_count == 0
      assert summary.complexity_count == 0
      assert summary.circular_dep_count == 2
      assert summary.suggestion_count == 5
      assert summary.total_issues == 8
    end
  end
end
