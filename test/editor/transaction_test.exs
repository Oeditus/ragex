defmodule Ragex.Editor.TransactionTest do
  use ExUnit.Case, async: true

  alias Ragex.Editor.{Transaction, Types}

  setup do
    temp_dir = System.tmp_dir!()
    test_dir = Path.join(temp_dir, "ragex_transaction_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "new/1" do
    test "creates empty transaction" do
      txn = Transaction.new()
      assert txn.edits == []
      assert txn.opts == []
    end

    test "creates transaction with options" do
      txn = Transaction.new(validate: false, format: true)
      assert txn.opts == [validate: false, format: true]
    end
  end

  describe "add/4" do
    test "adds edit to transaction" do
      changes = [Types.replace(1, 1, "new")]
      txn = Transaction.new() |> Transaction.add("file.ex", changes)

      assert length(txn.edits) == 1
      assert hd(txn.edits).path == "file.ex"
      assert hd(txn.edits).changes == changes
    end

    test "adds multiple edits" do
      txn =
        Transaction.new()
        |> Transaction.add("file1.ex", [Types.replace(1, 1, "a")])
        |> Transaction.add("file2.ex", [Types.replace(2, 2, "b")])
        |> Transaction.add("file3.ex", [Types.replace(3, 3, "c")])

      assert length(txn.edits) == 3
      assert Enum.map(txn.edits, & &1.path) == ["file1.ex", "file2.ex", "file3.ex"]
    end

    test "supports per-file options" do
      txn =
        Transaction.new()
        |> Transaction.add("file1.ex", [Types.replace(1, 1, "a")], validate: false)
        |> Transaction.add("file2.ex", [Types.replace(1, 1, "b")], format: true)

      assert Enum.at(txn.edits, 0).opts == [validate: false]
      assert Enum.at(txn.edits, 1).opts == [format: true]
    end
  end

  describe "validate/1" do
    test "validates all edits successfully", %{test_dir: dir} do
      file1 = Path.join(dir, "file1.ex")
      file2 = Path.join(dir, "file2.ex")
      File.write!(file1, "defmodule Test1 do\nend\n")
      File.write!(file2, "defmodule Test2 do\nend\n")

      txn =
        Transaction.new()
        |> Transaction.add(file1, [
          Types.replace(1, 2, "defmodule Test1 do\n  def hello, do: :world\nend")
        ])
        |> Transaction.add(file2, [
          Types.replace(1, 2, "defmodule Test2 do\n  def goodbye, do: :ok\nend")
        ])

      assert {:ok, :valid} = Transaction.validate(txn)
    end

    test "detects validation errors", %{test_dir: dir} do
      file1 = Path.join(dir, "file1.ex")
      File.write!(file1, "defmodule Test do\nend\n")

      # Invalid Elixir code (missing end)
      txn =
        Transaction.new()
        |> Transaction.add(file1, [Types.replace(1, 2, "defmodule Test do")])

      assert {:error, errors} = Transaction.validate(txn)
      assert length(errors) == 1
      assert {^file1, _validation_errors} = hd(errors)
    end

    test "validates without applying changes", %{test_dir: dir} do
      file1 = Path.join(dir, "file1.ex")
      original_content = "defmodule Test do\nend\n"
      File.write!(file1, original_content)

      txn =
        Transaction.new()
        |> Transaction.add(file1, [
          Types.replace(1, 2, "defmodule Test do\n  def hello, do: :world\nend")
        ])

      assert {:ok, :valid} = Transaction.validate(txn)

      # File should not be modified
      assert File.read!(file1) == original_content
    end
  end

  describe "commit/1" do
    test "commits single file edit", %{test_dir: dir} do
      file1 = Path.join(dir, "file1.txt")
      File.write!(file1, "line 1\nline 2\n")

      txn =
        Transaction.new(validate: false)
        |> Transaction.add(file1, [Types.replace(1, 1, "modified line 1")])

      assert {:ok, result} = Transaction.commit(txn)
      assert result.status == :success
      assert result.files_edited == 1
      assert result.rolled_back == false

      # Verify change applied
      assert File.read!(file1) == "modified line 1\nline 2\n"
    end

    test "commits multiple file edits atomically", %{test_dir: dir} do
      file1 = Path.join(dir, "file1.txt")
      file2 = Path.join(dir, "file2.txt")
      file3 = Path.join(dir, "file3.txt")

      File.write!(file1, "file1\n")
      File.write!(file2, "file2\n")
      File.write!(file3, "file3\n")

      txn =
        Transaction.new(validate: false)
        |> Transaction.add(file1, [Types.replace(1, 1, "modified file1")])
        |> Transaction.add(file2, [Types.replace(1, 1, "modified file2")])
        |> Transaction.add(file3, [Types.replace(1, 1, "modified file3")])

      assert {:ok, result} = Transaction.commit(txn)
      assert result.status == :success
      assert result.files_edited == 3
      assert length(result.results) == 3

      # Verify all changes applied
      assert File.read!(file1) == "modified file1\n"
      assert File.read!(file2) == "modified file2\n"
      assert File.read!(file3) == "modified file3\n"
    end

    test "fails validation before editing files", %{test_dir: dir} do
      file1 = Path.join(dir, "file1.ex")
      file2 = Path.join(dir, "file2.ex")

      original1 = "defmodule Test1 do\nend\n"
      original2 = "defmodule Test2 do\nend\n"

      File.write!(file1, original1)
      File.write!(file2, original2)

      # Second edit has invalid syntax - validation should fail before any edits
      txn =
        Transaction.new()
        |> Transaction.add(file1, [
          Types.replace(1, 2, "defmodule Test1 do\n  def hello, do: :world\nend")
        ])
        # Missing end
        |> Transaction.add(file2, [Types.replace(1, 2, "defmodule Test2 do")])

      assert {:error, result} = Transaction.commit(txn)
      assert result.status == :failure
      # Validation failed, no files edited
      assert result.files_edited == 0
      # Nothing to rollback
      assert result.rolled_back == false

      # Files should remain unchanged
      assert File.read!(file1) == original1
      assert File.read!(file2) == original2
    end

    test "handles file read errors gracefully", %{test_dir: dir} do
      nonexistent = Path.join(dir, "nonexistent.txt")

      txn =
        Transaction.new(validate: false)
        |> Transaction.add(nonexistent, [Types.replace(1, 1, "new")])

      assert {:error, result} = Transaction.commit(txn)
      assert result.status == :failure
      assert result.files_edited == 0
    end

    test "creates backups for all files", %{test_dir: dir} do
      file1 = Path.join(dir, "file1.txt")
      file2 = Path.join(dir, "file2.txt")

      File.write!(file1, "original1\n")
      File.write!(file2, "original2\n")

      txn =
        Transaction.new(validate: false)
        |> Transaction.add(file1, [Types.replace(1, 1, "modified1")])
        |> Transaction.add(file2, [Types.replace(1, 1, "modified2")])

      assert {:ok, result} = Transaction.commit(txn)

      # Check that backups were created
      assert Enum.all?(result.results, fn r -> r.backup_id != nil end)
    end

    test "respects transaction-wide options", %{test_dir: dir} do
      file1 = Path.join(dir, "file1.txt")
      File.write!(file1, "original\n")

      # Transaction with validate: false
      txn =
        Transaction.new(validate: false)
        |> Transaction.add(file1, [Types.replace(1, 1, "modified")])

      assert {:ok, result} = Transaction.commit(txn)
      assert result.status == :success
    end

    test "per-file options override transaction options", %{test_dir: dir} do
      file1 = Path.join(dir, "file1.ex")
      file2 = Path.join(dir, "file2.ex")

      File.write!(file1, "defmodule Test1 do\nend\n")
      File.write!(file2, "defmodule Test2 do\nend\n")

      # Transaction has validate: false, but file2 overrides with validate: true
      txn =
        Transaction.new(validate: false)
        |> Transaction.add(file1, [
          Types.replace(1, 2, "defmodule Test1 do\n  def hello, do: :world\nend")
        ])
        |> Transaction.add(
          file2,
          [Types.replace(1, 2, "defmodule Test2 do\n  def goodbye, do: :ok\nend")],
          validate: true
        )

      assert {:ok, result} = Transaction.commit(txn)
      assert result.status == :success
    end
  end

  describe "error handling" do
    test "provides detailed error information on validation failure", %{test_dir: dir} do
      file1 = Path.join(dir, "file1.ex")
      File.write!(file1, "defmodule Test do\nend\n")

      txn =
        Transaction.new()
        |> Transaction.add(file1, [Types.replace(1, 2, "defmodule Test do")])

      assert {:error, result} = Transaction.commit(txn)
      assert result.status == :failure
      assert length(result.errors) > 0
    end

    test "rolls back partial changes on file error", %{test_dir: dir} do
      file1 = Path.join(dir, "file1.txt")
      file2 = Path.join(dir, "nonexistent.txt")

      original1 = "original\n"
      File.write!(file1, original1)

      txn =
        Transaction.new(validate: false)
        |> Transaction.add(file1, [Types.replace(1, 1, "modified")])
        # Will fail - file doesn't exist
        |> Transaction.add(file2, [Types.replace(1, 1, "new")])

      assert {:error, result} = Transaction.commit(txn)
      # First file was edited
      assert result.files_edited == 1
      # Should have rolled back
      assert result.rolled_back == true

      # First file should be restored
      assert File.read!(file1) == original1
    end
  end
end
