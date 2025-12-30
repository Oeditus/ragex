defmodule Ragex.MCP.Handlers.EditToolsTest do
  use ExUnit.Case, async: true

  alias Ragex.MCP.Handlers.Tools

  setup do
    # Create a temporary directory for test files
    temp_dir = System.tmp_dir!()
    test_dir = Path.join(temp_dir, "ragex_edit_tools_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "edit_file tool" do
    test "edits a file with replace change", %{test_dir: dir} do
      # Create test file
      test_file = Path.join(dir, "test.txt")
      File.write!(test_file, "line 1\nline 2\nline 3\n")

      # Edit the file
      params = %{
        "path" => test_file,
        "changes" => [
          %{
            "type" => "replace",
            "line_start" => 2,
            "line_end" => 2,
            "content" => "new line 2"
          }
        ],
        "validate" => false
      }

      assert {:ok, result} = Tools.call_tool("edit_file", params)
      assert result.status == "success"
      assert result.changes_applied == 1
      assert result.validation_performed == false
      assert result.backup_id

      # Verify file content
      assert File.read!(test_file) == "line 1\nnew line 2\nline 3\n"
    end

    test "edits a file with insert change", %{test_dir: dir} do
      test_file = Path.join(dir, "test.txt")
      File.write!(test_file, "line 1\nline 3\n")

      params = %{
        "path" => test_file,
        "changes" => [
          %{
            "type" => "insert",
            "line_start" => 2,
            "content" => "line 2"
          }
        ],
        "validate" => false
      }

      assert {:ok, result} = Tools.call_tool("edit_file", params)
      assert result.status == "success"
      assert File.read!(test_file) == "line 1\nline 2\nline 3\n"
    end

    test "edits a file with delete change", %{test_dir: dir} do
      test_file = Path.join(dir, "test.txt")
      File.write!(test_file, "line 1\nline 2\nline 3\n")

      params = %{
        "path" => test_file,
        "changes" => [
          %{
            "type" => "delete",
            "line_start" => 2,
            "line_end" => 2
          }
        ],
        "validate" => false
      }

      assert {:ok, result} = Tools.call_tool("edit_file", params)
      assert result.status == "success"
      assert File.read!(test_file) == "line 1\nline 3\n"
    end

    test "validates Elixir code when enabled", %{test_dir: dir} do
      test_file = Path.join(dir, "test.ex")
      File.write!(test_file, "defmodule Test do\nend\n")

      # Valid change
      params = %{
        "path" => test_file,
        "changes" => [
          %{
            "type" => "replace",
            "line_start" => 1,
            "line_end" => 2,
            "content" => "defmodule Test do\n  def hello, do: :world\nend"
          }
        ],
        "validate" => true
      }

      assert {:ok, result} = Tools.call_tool("edit_file", params)
      assert result.status == "success"
      assert result.validation_performed == true
    end

    test "rejects invalid Elixir code", %{test_dir: dir} do
      test_file = Path.join(dir, "test.ex")
      File.write!(test_file, "defmodule Test do\nend\n")

      # Invalid change
      params = %{
        "path" => test_file,
        "changes" => [
          %{
            "type" => "replace",
            "line_start" => 1,
            "line_end" => 2,
            "content" => "defmodule Test do"
          }
        ],
        "validate" => true
      }

      assert {:error, error} = Tools.call_tool("edit_file", params)
      assert error["type"] == "validation_error"
      assert is_list(error["errors"])
      assert error["errors"] != []
    end

    test "supports language override", %{test_dir: dir} do
      test_file = Path.join(dir, "script")
      File.write!(test_file, "x = 1\n")

      params = %{
        "path" => test_file,
        "changes" => [
          %{
            "type" => "replace",
            "line_start" => 1,
            "line_end" => 1,
            "content" => "defmodule Test, do: :ok"
          }
        ],
        "language" => "elixir",
        "validate" => true
      }

      assert {:ok, result} = Tools.call_tool("edit_file", params)
      assert result.validation_performed == true
    end
  end

  describe "validate_edit tool" do
    test "validates valid changes", %{test_dir: dir} do
      test_file = Path.join(dir, "test.ex")
      File.write!(test_file, "defmodule Test do\nend\n")

      params = %{
        "path" => test_file,
        "changes" => [
          %{
            "type" => "replace",
            "line_start" => 1,
            "line_end" => 2,
            "content" => "defmodule Test do\n  def hello, do: :world\nend"
          }
        ]
      }

      assert {:ok, result} = Tools.call_tool("validate_edit", params)
      assert result.status == "valid"
      assert result.message == "Changes are valid"

      # File should not be modified
      assert File.read!(test_file) == "defmodule Test do\nend\n"
    end

    test "detects invalid changes", %{test_dir: dir} do
      test_file = Path.join(dir, "test.ex")
      File.write!(test_file, "defmodule Test do\nend\n")

      params = %{
        "path" => test_file,
        "changes" => [
          %{
            "type" => "replace",
            "line_start" => 1,
            "line_end" => 2,
            "content" => "defmodule Test do"
          }
        ]
      }

      assert {:ok, result} = Tools.call_tool("validate_edit", params)
      assert result.status == "invalid"
      assert is_list(result.errors)
      assert result.errors != []

      # File should not be modified
      assert File.read!(test_file) == "defmodule Test do\nend\n"
    end
  end

  describe "rollback_edit tool" do
    test "rolls back to most recent backup", %{test_dir: dir} do
      test_file = Path.join(dir, "test.txt")
      original_content = "original content\n"
      File.write!(test_file, original_content)

      # Make an edit
      edit_params = %{
        "path" => test_file,
        "changes" => [
          %{
            "type" => "replace",
            "line_start" => 1,
            "line_end" => 1,
            "content" => "modified content"
          }
        ],
        "validate" => false
      }

      assert {:ok, _} = Tools.call_tool("edit_file", edit_params)
      assert File.read!(test_file) != original_content

      # Rollback
      rollback_params = %{"path" => test_file}
      assert {:ok, result} = Tools.call_tool("rollback_edit", rollback_params)
      assert result.status == "restored"
      assert result.backup_id

      # File should be restored
      assert File.read!(test_file) == original_content
    end

    test "rolls back to specific backup", %{test_dir: dir} do
      test_file = Path.join(dir, "test.txt")
      File.write!(test_file, "version 1\n")

      # Make first edit
      edit1 = %{
        "path" => test_file,
        "changes" => [
          %{"type" => "replace", "line_start" => 1, "line_end" => 1, "content" => "version 2"}
        ],
        "validate" => false
      }

      {:ok, result1} = Tools.call_tool("edit_file", edit1)
      first_backup_id = result1.backup_id

      # Make second edit
      edit2 = %{
        "path" => test_file,
        "changes" => [
          %{"type" => "replace", "line_start" => 1, "line_end" => 1, "content" => "version 3"}
        ],
        "validate" => false
      }

      assert {:ok, _result2} = Tools.call_tool("edit_file", edit2)

      # Rollback to first backup
      rollback_params = %{"path" => test_file, "backup_id" => first_backup_id}
      assert {:ok, result} = Tools.call_tool("rollback_edit", rollback_params)
      assert result.backup_id == first_backup_id

      # File should be version 1
      assert File.read!(test_file) == "version 1\n"
    end
  end

  describe "edit_history tool" do
    test "returns edit history", %{test_dir: dir} do
      test_file = Path.join(dir, "test.txt")
      File.write!(test_file, "initial\n")

      # Make a few edits
      for i <- 1..3 do
        params = %{
          "path" => test_file,
          "changes" => [
            %{"type" => "replace", "line_start" => 1, "line_end" => 1, "content" => "edit #{i}"}
          ],
          "validate" => false
        }

        assert {:ok, _} = Tools.call_tool("edit_file", params)
      end

      # Get history
      history_params = %{"path" => test_file}
      assert {:ok, result} = Tools.call_tool("edit_history", history_params)
      assert result.path == test_file
      assert result.count >= 3
      assert is_list(result.backups)
      assert length(result.backups) >= 3

      # Check backup structure
      backup = List.first(result.backups)
      assert Map.has_key?(backup, :id)
      assert Map.has_key?(backup, :timestamp)
      assert Map.has_key?(backup, :size_bytes)
      assert Map.has_key?(backup, :path)
    end

    test "respects limit parameter", %{test_dir: dir} do
      test_file = Path.join(dir, "test.txt")
      File.write!(test_file, "initial\n")

      # Make 5 edits
      for i <- 1..5 do
        params = %{
          "path" => test_file,
          "changes" => [
            %{"type" => "replace", "line_start" => 1, "line_end" => 1, "content" => "edit #{i}"}
          ],
          "validate" => false
        }

        assert {:ok, _} = Tools.call_tool("edit_file", params)
      end

      # Get history with limit
      history_params = %{"path" => test_file, "limit" => 2}
      assert {:ok, result} = Tools.call_tool("edit_history", history_params)
      assert length(result.backups) <= 2
    end
  end

  describe "error handling" do
    test "edit_file returns error for non-existent file" do
      params = %{
        "path" => "/nonexistent/file.txt",
        "changes" => [
          %{"type" => "replace", "line_start" => 1, "line_end" => 1, "content" => "test"}
        ],
        "validate" => false
      }

      assert {:error, error} = Tools.call_tool("edit_file", params)
      assert is_binary(error)
    end

    test "edit_file returns error for invalid change structure" do
      params = %{
        "path" => "test.txt",
        "changes" => [%{"invalid" => "structure"}],
        "validate" => false
      }

      assert {:error, error} = Tools.call_tool("edit_file", params)
      assert is_binary(error)
    end

    test "validate_edit handles missing file" do
      params = %{
        "path" => "/nonexistent/file.ex",
        "changes" => [
          %{"type" => "replace", "line_start" => 1, "line_end" => 1, "content" => "test"}
        ]
      }

      assert {:error, error} = Tools.call_tool("validate_edit", params)
      assert is_binary(error)
    end

    test "rollback_edit handles no backups" do
      params = %{"path" => "/nonexistent/file.txt"}
      assert {:error, error} = Tools.call_tool("rollback_edit", params)
      assert is_binary(error)
    end
  end
end
