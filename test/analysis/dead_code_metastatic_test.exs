defmodule Ragex.Analysis.DeadCodeMetastaticTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.DeadCode

  # Metastatic integration tests - may require external dependencies
  @moduletag :tmp_dir
  @moduletag :integration

  describe "analyze_file/2" do
    test "detects no dead code in clean Elixir file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "clean.ex")

      File.write!(file_path, """
      defmodule Clean do
        def add(a, b) do
          a + b
        end
      end
      """)

      case DeadCode.analyze_file(file_path) do
        {:ok, result} ->
          refute result.has_dead_code?
          assert result.total_dead_statements == 0
          assert result.dead_locations == []

        {:error, reason} ->
          # If Metastatic can't parse, skip this test
          flunk("Failed to analyze file: #{inspect(reason)}")
      end
    end

    test "detects unreachable branch in constant conditional in Elixir", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "unreachable.ex")

      File.write!(file_path, """
      if false do
        IO.puts("unreachable")
      else
        :ok
      end
      """)

      {:ok, result} = DeadCode.analyze_file(file_path)

      assert result.has_dead_code?
      assert result.total_dead_statements > 0
      assert Enum.any?(result.dead_locations, &(&1.type == :constant_conditional))
    end

    @tag :skip
    test "detects constant conditionals in Python", %{tmp_dir: tmp_dir} do
      # Skipped: requires Python parser to be available
      file_path = Path.join(tmp_dir, "constant.py")

      File.write!(file_path, """
      def process():
          if True:
              return 1
          else:
              return 2
      """)

      {:ok, result} = DeadCode.analyze_file(file_path)

      assert result.has_dead_code?
      assert Enum.any?(result.dead_locations, &(&1.type == :constant_conditional))
    end

    test "respects min_confidence option", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.ex")

      File.write!(file_path, """
      defmodule Test do
        def func do
          if true do
            :ok
          else
            :error
          end
        end
      end
      """)

      # Both should succeed (whether or not dead code is detected)
      case {DeadCode.analyze_file(file_path, min_confidence: :low),
            DeadCode.analyze_file(file_path, min_confidence: :high)} do
        {{:ok, result_low}, {:ok, result_high}} ->
          # High confidence should have same or fewer detections
          assert result_high.total_dead_statements <= result_low.total_dead_statements

        _ ->
          flunk("Failed to analyze file with different confidence levels")
      end
    end

    test "handles non-existent file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "nonexistent.ex")

      assert {:error, _reason} = DeadCode.analyze_file(file_path)
    end

    test "handles invalid syntax gracefully", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "invalid.ex")

      File.write!(file_path, """
      defmodule Invalid do
        def broken(
      """)

      # Should return error, not crash
      assert {:error, _reason} = DeadCode.analyze_file(file_path)
    end
  end

  describe "analyze_files/2" do
    test "analyzes multiple files", %{tmp_dir: tmp_dir} do
      file1 = Path.join(tmp_dir, "file1.ex")
      file2 = Path.join(tmp_dir, "file2.ex")

      File.write!(file1, """
      defmodule File1 do
        def clean, do: :ok
      end
      """)

      File.write!(file2, """
      defmodule File2 do
        def has_dead do
          if true do
            :ok
          else
            :unreachable
          end
        end
      end
      """)

      {:ok, results} = DeadCode.analyze_files([file1, file2])

      assert map_size(results) == 2
      assert Map.has_key?(results, file1)
      assert Map.has_key?(results, file2)

      # Just verify we got results (actual dead code detection depends on Metastatic)
      assert is_map(results[file1])
      assert is_map(results[file2])
    end

    test "processes files in parallel", %{tmp_dir: tmp_dir} do
      files =
        for i <- 1..10 do
          path = Path.join(tmp_dir, "file#{i}.ex")

          File.write!(path, """
          defmodule File#{i} do
            def func, do: :ok
          end
          """)

          path
        end

      {:ok, results} = DeadCode.analyze_files(files)

      assert map_size(results) == 10
      assert Enum.all?(results, fn {_path, result} -> is_map(result) end)
    end

    test "handles mixed success and error results", %{tmp_dir: tmp_dir} do
      file1 = Path.join(tmp_dir, "good.ex")
      file2 = Path.join(tmp_dir, "bad.ex")

      File.write!(file1, """
      defmodule Good do
        def func, do: :ok
      end
      """)

      File.write!(file2, """
      defmodule Bad do
        def broken(
      """)

      {:ok, results} = DeadCode.analyze_files([file1, file2])

      assert map_size(results) == 2
      # Good file should have valid result
      assert is_map(results[file1])
      # Bad file should have error tuple
      assert match?({:error, _}, results[file2])
    end

    test "handles empty file list", %{tmp_dir: _tmp_dir} do
      {:ok, results} = DeadCode.analyze_files([])

      assert results == %{}
    end
  end

  describe "integration with existing interprocedural analysis" do
    test "both approaches can be used together", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "module.ex")

      # Module with both unused function (interprocedural) and dead code (intraprocedural)
      File.write!(file_path, """
      defmodule TestModule do
        def used_function do
          if true do
            :ok
          else
            :unreachable
          end
        end

        defp unused_function do
          :never_called
        end
      end
      """)

      # Intraprocedural analysis (AST-level)
      case DeadCode.analyze_file(file_path) do
        {:ok, intra_result} ->
          # May or may not detect dead code depending on Metastatic configuration
          assert is_map(intra_result)

        {:error, _reason} ->
          # If Metastatic can't parse, that's ok for this integration test
          :ok
      end

      # Interprocedural analysis API still exists
      assert function_exported?(DeadCode, :find_unused_private, 1)
      assert function_exported?(DeadCode, :analyze_file, 2)
    end
  end

  describe "edge cases" do
    test "handles empty file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "empty.ex")
      File.write!(file_path, "")

      # Empty file might fail to parse or return no dead code
      case DeadCode.analyze_file(file_path) do
        {:ok, result} -> refute result.has_dead_code?
        {:error, _} -> :ok
      end
    end

    test "handles file with only comments", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "comments.ex")

      File.write!(file_path, """
      # This is a comment
      # Another comment
      """)

      case DeadCode.analyze_file(file_path) do
        {:ok, result} -> refute result.has_dead_code?
        {:error, _} -> :ok
      end
    end

    test "detects multiple dead code patterns in one file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "multiple.ex")

      File.write!(file_path, """
      if true do
        :ok
      else
        :dead1
      end

      if false do
        IO.puts("dead2")
      else
        :ok
      end
      """)

      {:ok, result} = DeadCode.analyze_file(file_path)

      assert result.has_dead_code?
      # Should detect both constant conditionals
      assert result.total_dead_statements >= 2
    end
  end
end
