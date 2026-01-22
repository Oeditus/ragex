defmodule Ragex.Editor.DiffTest do
  use ExUnit.Case, async: true

  alias Ragex.Editor.Diff

  describe "generate/3" do
    test "generates unified diff for simple changes" do
      original = "line 1\nline 2\nline 3"
      modified = "line 1\nline 2 modified\nline 3"

      {:ok, result} = Diff.generate(original, modified, "test.ex")

      assert result.file_path == "test.ex"
      assert result.format == :unified
      assert result.stats.added == 1
      assert result.stats.removed == 1
      assert String.contains?(result.unified_diff, "+line 2 modified")
      assert String.contains?(result.unified_diff, "-line 2")
    end

    test "generates side-by-side diff" do
      original = "line 1\nline 2"
      modified = "line 1\nline 2 changed"

      {:ok, result} = Diff.generate(original, modified, "test.ex", format: :side_by_side)

      assert result.format == :side_by_side
      assert String.contains?(result.side_by_side_diff, "line 2")
      assert String.contains?(result.side_by_side_diff, "line 2 changed")
    end

    test "generates JSON diff" do
      original = "line 1\nline 2"
      modified = "line 1\nline 3"

      {:ok, result} = Diff.generate(original, modified, "test.ex", format: :json)

      assert result.format == :json
      assert is_map(result.json_diff)
      assert [_, _] = result.json_diff.changes
    end

    test "generates HTML diff" do
      original = "line 1"
      modified = "line 2"

      {:ok, result} = Diff.generate(original, modified, "test.ex", format: :html)

      assert result.format == :html
      assert String.contains?(result.html_diff, "<div")
      assert String.contains?(result.html_diff, "line 1")
      assert String.contains?(result.html_diff, "line 2")
    end

    test "handles empty files" do
      {:ok, result} = Diff.generate("", "", "empty.ex")

      assert result.stats.added == 0
      assert result.stats.removed == 0
      assert result.stats.unchanged == 0
    end

    test "handles additions only" do
      original = ""
      modified = "new line 1\nnew line 2"

      {:ok, result} = Diff.generate(original, modified, "test.ex")

      assert result.stats.added == 2
      assert result.stats.removed == 0
    end

    test "handles deletions only" do
      original = "line 1\nline 2"
      modified = ""

      {:ok, result} = Diff.generate(original, modified, "test.ex")

      assert result.stats.added == 0
      assert result.stats.removed == 2
    end

    test "respects context lines option" do
      original = "1\n2\n3\n4\n5"
      modified = "1\n2\nX\n4\n5"

      {:ok, result} = Diff.generate(original, modified, "test.ex", context_lines: 1)

      assert String.contains?(result.unified_diff, "2")
      assert String.contains?(result.unified_diff, "4")
    end
  end

  describe "compare_files/3" do
    setup do
      # Create temp files for testing
      dir = System.tmp_dir!()
      file1 = Path.join(dir, "test1_#{:rand.uniform(10000)}.ex")
      file2 = Path.join(dir, "test2_#{:rand.uniform(10000)}.ex")

      File.write!(file1, "line 1\nline 2")
      File.write!(file2, "line 1\nline 3")

      on_exit(fn ->
        File.rm(file1)
        File.rm(file2)
      end)

      %{file1: file1, file2: file2}
    end

    test "compares two files", %{file1: file1, file2: file2} do
      {:ok, result} = Diff.compare_files(file1, file2)

      assert result.file_path == file2
      assert result.stats.added == 1
      assert result.stats.removed == 1
    end

    test "returns error for non-existent file" do
      assert {:error, _} = Diff.compare_files("nonexistent1.ex", "nonexistent2.ex")
    end
  end

  describe "stats calculation" do
    test "correctly counts additions and deletions" do
      original = "a\nb\nc"
      modified = "a\nX\nc\nY"

      {:ok, result} = Diff.generate(original, modified, "test.ex")

      assert result.stats.added == 2
      assert result.stats.removed == 1
      assert result.stats.unchanged == 2
    end

    test "handles complex multi-line changes" do
      original = """
      def foo do
        x = 1
        y = 2
      end
      """

      modified = """
      def foo do
        x = 1
        y = 3
        z = 4
      end
      """

      {:ok, result} = Diff.generate(original, modified, "test.ex")

      assert result.stats.added > 0
      assert result.stats.removed > 0
    end
  end
end
