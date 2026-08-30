defmodule Ragex.Dllb.ProjectManagerTest do
  use ExUnit.Case, async: false

  alias Ragex.Dllb.ProjectManager

  setup do
    old_mode = Application.get_env(:ragex, :dllb_mode)
    old_bin = Application.get_env(:ragex, :dllb_server_bin)

    on_exit(fn ->
      if old_mode,
        do: Application.put_env(:ragex, :dllb_mode, old_mode),
        else: Application.delete_env(:ragex, :dllb_mode)

      if old_bin,
        do: Application.put_env(:ragex, :dllb_server_bin, old_bin),
        else: Application.delete_env(:ragex, :dllb_server_bin)
    end)

    :ok
  end

  describe "configuration & detection" do
    test "mode/0 returns :global by default" do
      Application.delete_env(:ragex, :dllb_mode)
      Application.delete_env(:ragex, :dllb_instance_per_project)
      assert ProjectManager.mode() == :global
      refute ProjectManager.per_project_enabled?()
    end

    test "mode/0 returns :per_project when configured" do
      Application.put_env(:ragex, :dllb_mode, :per_project)
      assert ProjectManager.mode() == :per_project
      assert ProjectManager.per_project_enabled?()
    end

    test "find_dllb_binary/0 locates dllb-server executable" do
      binary = ProjectManager.find_dllb_binary()

      if binary do
        assert File.exists?(binary)
        assert String.contains?(binary, "dllb-server")
      end
    end
  end

  describe "project lifecycle" do
    test "ensure_instance creates .ragex directory and attempts server launch" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ragex_proj_manager_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        ProjectManager.stop_instance(tmp_dir)
        File.rm_rf!(tmp_dir)
      end)

      binary = ProjectManager.find_dllb_binary()

      if binary do
        assert {:ok, info} = ProjectManager.ensure_instance(tmp_dir)
        assert info.project_path == Path.expand(tmp_dir)
        assert File.dir?(Path.join(tmp_dir, ".ragex"))
        assert info.db_path == Path.join(tmp_dir, ".ragex/dllb.redb")
        assert is_atom(info.pool)

        ProjectManager.set_active_project(tmp_dir)
        assert ProjectManager.active_project() == Path.expand(tmp_dir)
      else
        # If binary is not available, ensure_instance returns :dllb_binary_not_found gracefully
        assert {:error, :dllb_binary_not_found} = ProjectManager.ensure_instance(tmp_dir)
      end
    end
  end

  describe "instance-state persistence & reattachment" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "ragex_proj_manager_reattach_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        ProjectManager.stop_instance(tmp_dir)
        File.rm_rf!(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "writes and removes an instance state file across the instance lifecycle", %{
      tmp_dir: tmp_dir
    } do
      binary = ProjectManager.find_dllb_binary()

      if binary do
        instance_file = Path.join(tmp_dir, ".ragex/dllb.instance.json")

        refute File.exists?(instance_file)

        assert {:ok, info} = ProjectManager.ensure_instance(tmp_dir)
        assert File.exists?(instance_file)

        {:ok, content} = File.read(instance_file)
        decoded = :json.decode(content)
        assert decoded["port"] == info.port

        ProjectManager.stop_instance(tmp_dir)
        refute File.exists?(instance_file)
      else
        :ok
      end
    end

    test "reattaches to an already-running dllb-server instead of double-spawning", %{
      tmp_dir: tmp_dir
    } do
      binary = ProjectManager.find_dllb_binary()

      if binary do
        assert {:ok, first_info} = ProjectManager.ensure_instance(tmp_dir)

        # Simulate a VM restart: the pool (a BEAM process) dies with the VM
        # and this manager forgets the instance in its in-memory state, but
        # the dllb-server OS process (and instance-state file) survive
        # exactly as they are, as if a fresh BEAM VM booted while the first
        # dllb-server was still alive and holding its redb lock.
        abs_path = Path.expand(tmp_dir)
        Process.exit(first_info.pool_pid, :kill)

        # Wait for the pool's registered name to actually free up before
        # attempting to reattach, so we're testing the "nothing registered
        # under this name" path rather than the already-started fallback.
        Process.sleep(50)

        :sys.replace_state(ProjectManager, fn state -> %{state | instances: %{}} end)

        assert {:ok, second_info} = ProjectManager.ensure_instance(abs_path)
        assert second_info.port == first_info.port
        assert second_info.pool == first_info.pool
        assert second_info.owned? == false

        # Stopping the adopted (non-owned) instance must not touch the
        # still-running process it doesn't own, nor delete the state file
        # the original owner relies on to find it again.
        instance_file = Path.join(tmp_dir, ".ragex/dllb.instance.json")
        ProjectManager.stop_instance(abs_path)
        assert File.exists?(instance_file)

        # Restore ownership tracking so the test's on_exit cleanup can
        # actually stop the real OS process.
        :sys.replace_state(ProjectManager, fn state ->
          %{state | instances: Map.put(state.instances, abs_path, first_info)}
        end)
      else
        :ok
      end
    end
  end
end
