defmodule Ragex.WatcherTest do
  use ExUnit.Case, async: false

  alias Ragex.Watcher

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "ragex_watcher_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      Watcher.unwatch_directory(tmp_dir)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "resolve_watch_directories/2" do
    test "by default watches only source directories like lib and test, ignoring .git", %{
      tmp_dir: tmp_dir
    } do
      lib_dir = Path.join(tmp_dir, "lib")
      test_dir = Path.join(tmp_dir, "test")
      git_dir = Path.join(tmp_dir, ".git")
      build_dir = Path.join(tmp_dir, "_build")

      File.mkdir_p!(lib_dir)
      File.mkdir_p!(test_dir)
      File.mkdir_p!(git_dir)
      File.mkdir_p!(build_dir)

      # Write a source file in .git to ensure even if source extensions exist inside .git, it is ignored
      File.write!(Path.join(git_dir, "hook.ex"), "defmodule Hook do; end")
      File.write!(Path.join(lib_dir, "app.ex"), "defmodule App do; end")
      File.write!(Path.join(test_dir, "app_test.exs"), "defmodule AppTest do; end")

      resolved = Watcher.resolve_watch_directories(tmp_dir)

      assert lib_dir in resolved
      assert test_dir in resolved
      refute git_dir in resolved
      refute build_dir in resolved
      refute tmp_dir in resolved
    end

    test "falls back to watching root if root directly contains source files and no subdirectories",
         %{tmp_dir: tmp_dir} do
      source_file = Path.join(tmp_dir, "script.exs")
      File.write!(source_file, "IO.puts(:hello)")

      resolved = Watcher.resolve_watch_directories(tmp_dir)

      assert resolved == [tmp_dir]
    end

    test "respects explicit dirs option", %{tmp_dir: tmp_dir} do
      custom_dir = Path.join(tmp_dir, "custom")
      File.mkdir_p!(custom_dir)

      resolved = Watcher.resolve_watch_directories(tmp_dir, dirs: ["custom"])

      assert resolved == [custom_dir]
    end

    test "respects only_source_dirs: false (or source_only: false) to watch root directly", %{
      tmp_dir: tmp_dir
    } do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      resolved1 = Watcher.resolve_watch_directories(tmp_dir, only_source_dirs: false)
      assert resolved1 == [tmp_dir]

      resolved2 = Watcher.resolve_watch_directories(tmp_dir, source_only: false)
      assert resolved2 == [tmp_dir]
    end

    test "watches directory directly when path itself is already a source directory name", %{
      tmp_dir: tmp_dir
    } do
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)

      resolved = Watcher.resolve_watch_directories(lib_dir)
      assert resolved == [lib_dir]
    end

    test "respects Application env config: :ragex, watcher: [dirs: [...]]", %{
      tmp_dir: tmp_dir
    } do
      dir_a = Path.join(tmp_dir, "dir_a")
      dir_b = Path.join(tmp_dir, "dir_b")
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)

      old_env = Application.get_env(:ragex, :watcher)

      try do
        Application.put_env(:ragex, :watcher, dirs: ["dir_a", "dir_b"])

        resolved = Watcher.resolve_watch_directories(tmp_dir)
        assert dir_a in resolved
        assert dir_b in resolved
        assert length(resolved) == 2

        # Runtime option overrides application env config
        dir_c = Path.join(tmp_dir, "dir_c")
        File.mkdir_p!(dir_c)

        override_resolved = Watcher.resolve_watch_directories(tmp_dir, dirs: ["dir_c"])
        assert override_resolved == [dir_c]
      after
        if old_env,
          do: Application.put_env(:ragex, :watcher, old_env),
          else: Application.delete_env(:ragex, :watcher)
      end
    end
  end

  describe "watch_directory/2 and unwatch_directory/1" do
    test "watches only source directories by default and un-watches when requested", %{
      tmp_dir: tmp_dir
    } do
      lib_dir = Path.join(tmp_dir, "lib")
      test_dir = Path.join(tmp_dir, "test")
      git_dir = Path.join(tmp_dir, ".git")

      File.mkdir_p!(lib_dir)
      File.mkdir_p!(test_dir)
      File.mkdir_p!(git_dir)

      assert :ok = Watcher.watch_directory(tmp_dir)

      watched = Watcher.list_watched()
      assert lib_dir in watched
      assert test_dir in watched
      refute git_dir in watched
      refute tmp_dir in watched

      assert Watcher.watching?(tmp_dir)
      assert Watcher.watching?(lib_dir)
      assert Watcher.watching?(test_dir)
      refute Watcher.watching?(git_dir)

      # Unwatch the entire project
      assert :ok = Watcher.unwatch_directory(tmp_dir)

      watched_after = Watcher.list_watched()
      refute lib_dir in watched_after
      refute test_dir in watched_after
      refute Watcher.watching?(tmp_dir)
    end

    test "unwatch_directory un-watches individual subdirectories", %{
      tmp_dir: tmp_dir
    } do
      lib_dir = Path.join(tmp_dir, "lib")
      test_dir = Path.join(tmp_dir, "test")

      File.mkdir_p!(lib_dir)
      File.mkdir_p!(test_dir)

      assert :ok = Watcher.watch_directory(tmp_dir)
      assert lib_dir in Watcher.list_watched()
      assert test_dir in Watcher.list_watched()

      # Unwatch only lib
      assert :ok = Watcher.unwatch_directory(lib_dir)
      watched_after = Watcher.list_watched()
      refute lib_dir in watched_after
      assert test_dir in watched_after
    end
  end

  describe "event handling" do
    test "ignores events from excluded directories like .git", %{
      tmp_dir: tmp_dir
    } do
      git_file = Path.join([tmp_dir, ".git", "hooks", "hook.ex"])
      File.mkdir_p!(Path.dirname(git_file))
      File.write!(git_file, "defmodule Hook do; end")

      # Send a file modification event for the .git file
      send(Watcher, {:file_event, self(), {git_file, [:modified]}})

      # Small sleep to check state
      Process.sleep(50)

      # Since it's in .git, it should never be added to pending files
      # (the debounce timer should not even be started for it)
      state = :sys.get_state(Watcher)
      refute MapSet.member?(state.pending_files, git_file)
    end
  end
end
