defmodule Ragex.CLI.ProgressTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias Ragex.CLI.Progress

  describe "bar/3" do
    test "renders progress bar at 50%" do
      output =
        capture_io(fn ->
          Progress.bar(50, 100)
        end)

      assert output =~ "50"
      assert output =~ "100"
      assert output =~ "%"
    end

    test "renders complete progress bar" do
      output =
        capture_io(fn ->
          Progress.bar(100, 100)
        end)

      assert output =~ "100"
      assert output =~ "\n"
    end

    test "renders progress bar with label" do
      output =
        capture_io(fn ->
          Progress.bar(25, 100, label: "Processing")
        end)

      assert output =~ "Processing"
      assert output =~ "25"
    end

    test "handles zero total gracefully" do
      output =
        capture_io(fn ->
          Progress.bar(0, 0)
        end)

      assert output != ""
    end

    test "hides percentage when option is false" do
      output =
        capture_io(fn ->
          Progress.bar(50, 100, show_percent: false)
        end)

      refute output =~ "%"
    end
  end

  describe "status/2" do
    test "renders success status" do
      output =
        capture_io(fn ->
          Progress.status("Operation complete", status: :success)
        end)

      assert output =~ "✓"
      assert output =~ "Operation complete"
    end

    test "renders error status" do
      output =
        capture_io(fn ->
          Progress.status("Failed", status: :error)
        end)

      assert output =~ "✗"
      assert output =~ "Failed"
    end

    test "renders warning status" do
      output =
        capture_io(fn ->
          Progress.status("Warning", status: :warning)
        end)

      assert output =~ "⚠"
      assert output =~ "Warning"
    end

    test "renders info status" do
      output =
        capture_io(fn ->
          Progress.status("Info", status: :info)
        end)

      assert output =~ "ℹ"
      assert output =~ "Info"
    end
  end

  describe "steps/2" do
    test "renders multi-step progress" do
      output =
        capture_io(fn ->
          Progress.steps(["Parse", "Analyze", "Generate"], 1)
        end)

      assert output =~ "Parse"
      assert output =~ "Analyze"
      assert output =~ "Generate"
      assert output =~ "[✓]"
      assert output =~ "[→]"
      assert output =~ "[ ]"
    end

    test "handles first step" do
      output =
        capture_io(fn ->
          Progress.steps(["Step 1", "Step 2"], 0)
        end)

      assert output =~ "[→]"
    end

    test "handles last step" do
      output =
        capture_io(fn ->
          Progress.steps(["Step 1", "Step 2"], 1)
        end)

      assert output =~ "[✓]"
      assert output =~ "[→]"
    end
  end

  describe "percent/2" do
    test "renders percentage" do
      output =
        capture_io(fn ->
          Progress.percent(75)
        end)

      assert output =~ "75%"
    end

    test "renders percentage with label" do
      output =
        capture_io(fn ->
          Progress.percent(50, label: "Upload")
        end)

      assert output =~ "Upload"
      assert output =~ "50%"
    end

    test "adds newline at 100%" do
      output =
        capture_io(fn ->
          Progress.percent(100)
        end)

      assert output =~ "\n"
    end
  end

  describe "task_list/1" do
    test "renders task list with different statuses" do
      output =
        capture_io(fn ->
          Progress.task_list([
            {"Fetch data", :done},
            {"Process", :running},
            {"Save", :pending},
            {"Validate", :error}
          ])
        end)

      assert output =~ "Fetch data"
      assert output =~ "Process"
      assert output =~ "Save"
      assert output =~ "Validate"
      assert output =~ "✓"
      assert output =~ "→"
      assert output =~ "◦"
      assert output =~ "✗"
    end

    test "handles empty task list" do
      output =
        capture_io(fn ->
          Progress.task_list([])
        end)

      assert output == ""
    end
  end

  describe "spinner/1 and stop_spinner/2" do
    test "starts and stops spinner" do
      pid = Progress.spinner(label: "Loading")
      assert Process.alive?(pid)

      :timer.sleep(200)

      output =
        capture_io(fn ->
          Progress.stop_spinner(pid, "Done!")
          # Give process time to terminate
          :timer.sleep(50)
        end)

      # Process may still be terminating, wait a bit
      :timer.sleep(50)
      refute Process.alive?(pid)
      assert output =~ "Done!"
    end

    test "stops spinner without message" do
      pid = Progress.spinner()
      assert Process.alive?(pid)

      :timer.sleep(100)

      capture_io(fn ->
        Progress.stop_spinner(pid)
        # Give process time to terminate
        :timer.sleep(50)
      end)

      # Process may still be terminating, wait a bit
      :timer.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "MCP stdio mode output routing" do
    setup do
      previous = Application.get_env(:ragex, :start_stdio_server)
      Application.put_env(:ragex, :start_stdio_server, true)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:ragex, :start_stdio_server)
        else
          Application.put_env(:ragex, :start_stdio_server, previous)
        end
      end)

      :ok
    end

    test "bar/3 routes progress to stderr and leaves stdout clean" do
      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              Progress.bar(1, 1, label: "Synthetic fixture")
            end)

          assert stdout == "", "human progress leaked onto MCP stdout: #{inspect(stdout)}"
        end)

      assert stderr =~ "Synthetic fixture"
      assert stderr =~ "100.0%"
    end

    test "status/2, steps/2, percent/2, and task_list/1 route to stderr in MCP stdio mode" do
      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              Progress.status("Indexed", status: :success)
              Progress.steps(["Parse", "Store"], 1)
              Progress.percent(100, label: "Index")
              Progress.task_list([{"Analyze", :done}])
            end)

          assert stdout == ""
        end)

      assert stderr =~ "Indexed"
      assert stderr =~ "Parse"
      assert stderr =~ "Index"
      assert stderr =~ "Analyze"
    end

    test "spinner/1 and stop_spinner/2 route to stderr in MCP stdio mode" do
      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              pid = Progress.spinner(label: "Indexing")
              :timer.sleep(100)
              Progress.stop_spinner(pid, "Done!")
              :timer.sleep(50)
            end)

          assert stdout == ""
        end)

      assert stderr =~ "Done!"
    end
  end
end
