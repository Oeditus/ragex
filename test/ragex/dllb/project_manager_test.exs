defmodule Ragex.Dllb.ProjectManagerTest do
  use ExUnit.Case, async: false

  alias Ragex.Dllb.ProjectManager

  setup do
    old_mode = Application.get_env(:ragex, :dllb_mode)
    old_bin = Application.get_env(:ragex, :dllb_server_bin)

    on_exit(fn ->
      if old_mode, do: Application.put_env(:ragex, :dllb_mode, old_mode), else: Application.delete_env(:ragex, :dllb_mode)
      if old_bin, do: Application.put_env(:ragex, :dllb_server_bin, old_bin), else: Application.delete_env(:ragex, :dllb_server_bin)
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
      tmp_dir = Path.join(System.tmp_dir!(), "ragex_proj_manager_test_#{System.unique_integer([:positive])}")
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
end
