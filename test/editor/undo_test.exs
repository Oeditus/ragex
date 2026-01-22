defmodule Ragex.Editor.UndoTest do
  use ExUnit.Case, async: false

  alias Ragex.Editor.Undo

  setup do
    # Use a unique project path for each test
    project_path = "/tmp/ragex_test_#{:rand.uniform(100_000)}"
    File.mkdir_p!(project_path)

    on_exit(fn ->
      # Clean up test project directory
      File.rm_rf!(project_path)

      # Clean up undo history
      project_hash =
        :crypto.hash(:sha256, project_path) |> Base.encode16(case: :lower) |> String.slice(0, 16)

      undo_dir = Path.join([System.user_home!(), ".ragex", "undo", project_hash])
      File.rm_rf(undo_dir)
    end)

    %{project_path: project_path}
  end

  describe "push_undo/5" do
    test "creates undo entry for operation", %{project_path: project_path} do
      file = Path.join(project_path, "test.ex")
      File.write!(file, "original content")

      params = %{module: :TestModule, old_name: :foo, new_name: :bar, arity: 2}

      {:ok, entry_id} =
        Undo.push_undo(project_path, :rename_function, params, [file], :success)

      assert is_binary(entry_id)
      assert String.length(entry_id) == 32
    end

    test "captures file states before operation", %{project_path: project_path} do
      file1 = Path.join(project_path, "file1.ex")
      file2 = Path.join(project_path, "file2.ex")

      File.write!(file1, "content 1")
      File.write!(file2, "content 2")

      params = %{module: :TestModule}

      {:ok, _entry_id} =
        Undo.push_undo(project_path, :extract_function, params, [file1, file2], :success)

      # Verify entry was created
      {:ok, entries} = Undo.list_undo_stack(project_path)
      assert [entry] = entries
      assert entry.operation == :extract_function
      assert Map.has_key?(entry.file_states, file1)
      assert Map.has_key?(entry.file_states, file2)
    end

    test "returns error for non-existent files", %{project_path: project_path} do
      params = %{}

      assert {:error, _} =
               Undo.push_undo(
                 project_path,
                 :rename_function,
                 params,
                 ["/nonexistent/file.ex"],
                 :success
               )
    end
  end

  describe "undo/1" do
    test "restores files to previous state", %{project_path: project_path} do
      file = Path.join(project_path, "test.ex")
      File.write!(file, "original content")

      params = %{module: :Test}
      {:ok, _} = Undo.push_undo(project_path, :rename_function, params, [file], :success)

      # Modify the file
      File.write!(file, "modified content")

      # Undo should restore original content
      {:ok, result} = Undo.undo(project_path)

      assert result.operation == :rename_function
      assert result.files_restored == 1
      assert File.read!(file) == "original content"
    end

    test "marks entry as undone", %{project_path: project_path} do
      file = Path.join(project_path, "test.ex")
      File.write!(file, "content")

      {:ok, _} =
        Undo.push_undo(project_path, :rename_function, %{}, [file], :success)

      {:ok, _} = Undo.undo(project_path)

      # List with include_undone
      {:ok, entries} = Undo.list_undo_stack(project_path, include_undone: true)
      assert [entry] = entries
      assert entry.undone == true
    end

    test "returns error when no history exists", %{project_path: project_path} do
      assert {:error, :no_undo_history} = Undo.undo(project_path)
    end

    test "returns error when already undone", %{project_path: project_path} do
      file = Path.join(project_path, "test.ex")
      File.write!(file, "content")

      {:ok, _} =
        Undo.push_undo(project_path, :rename_function, %{}, [file], :success)

      {:ok, _} = Undo.undo(project_path)

      # Try to undo again
      assert {:error, :already_undone} = Undo.undo(project_path)
    end
  end

  describe "list_undo_stack/2" do
    test "lists undo history", %{project_path: project_path} do
      file = Path.join(project_path, "test.ex")
      File.write!(file, "content")

      {:ok, _} =
        Undo.push_undo(project_path, :rename_function, %{test: 1}, [file], :success)

      {:ok, _} =
        Undo.push_undo(project_path, :extract_function, %{test: 2}, [file], :success)

      {:ok, entries} = Undo.list_undo_stack(project_path)

      assert [entry1, entry2] = entries
      # Most recent first
      assert entry1.operation == :extract_function
      assert entry2.operation == :rename_function
    end

    test "respects limit option", %{project_path: project_path} do
      file = Path.join(project_path, "test.ex")
      File.write!(file, "content")

      for i <- 1..5 do
        {:ok, _} =
          Undo.push_undo(
            project_path,
            :rename_function,
            %{index: i},
            [file],
            :success
          )
      end

      {:ok, entries} = Undo.list_undo_stack(project_path, limit: 3)

      assert length(entries) == 3
    end

    test "filters undone entries by default", %{project_path: project_path} do
      file = Path.join(project_path, "test.ex")
      File.write!(file, "content")

      {:ok, _} =
        Undo.push_undo(project_path, :rename_function, %{}, [file], :success)

      {:ok, _} = Undo.undo(project_path)

      {:ok, entries} = Undo.list_undo_stack(project_path)
      assert entries == []

      {:ok, entries_with_undone} = Undo.list_undo_stack(project_path, include_undone: true)
      assert [_] = entries_with_undone
    end

    test "returns error when no history", %{project_path: project_path} do
      # When no undo directory exists, returns error
      assert {:error, :no_undo_history} = Undo.list_undo_stack(project_path)
    end
  end

  describe "clear_undo_stack/2" do
    test "clears all undo history", %{project_path: project_path} do
      file = Path.join(project_path, "test.ex")
      File.write!(file, "content")

      for i <- 1..3 do
        {:ok, _} =
          Undo.push_undo(
            project_path,
            :rename_function,
            %{index: i},
            [file],
            :success
          )
      end

      {:ok, count} = Undo.clear_undo_stack(project_path)
      assert count == 3

      {:ok, entries} = Undo.list_undo_stack(project_path, include_undone: true)
      assert entries == []
    end

    test "respects keep_last option", %{project_path: project_path} do
      file = Path.join(project_path, "test.ex")
      File.write!(file, "content")

      for i <- 1..5 do
        {:ok, _} =
          Undo.push_undo(
            project_path,
            :rename_function,
            %{index: i},
            [file],
            :success
          )
      end

      {:ok, count} = Undo.clear_undo_stack(project_path, keep_last: 2)
      assert count == 3

      {:ok, entries} = Undo.list_undo_stack(project_path)
      assert length(entries) == 2
    end
  end

  describe "operation descriptions" do
    test "generates correct descriptions for different operations", %{
      project_path: project_path
    } do
      file = Path.join(project_path, "test.ex")
      File.write!(file, "content")

      operations = [
        {:rename_function, %{module: :Foo, old_name: :bar, new_name: :baz, arity: 2}},
        {:rename_module, %{old_name: :Old, new_name: :New}},
        {:extract_function, %{module: :Foo, source_function: :big, new_function: :small}},
        {:inline_function, %{module: :Foo, function: :helper, arity: 1}},
        {:move_function, %{source_module: :Src, target_module: :Dst, function: :func, arity: 0}}
      ]

      for {op, params} <- operations do
        {:ok, _} = Undo.push_undo(project_path, op, params, [file], :success)
      end

      {:ok, entries} = Undo.list_undo_stack(project_path)

      assert length(entries) == length(operations)
      assert Enum.all?(entries, &(String.length(&1.description) > 0))
    end
  end
end
