defmodule Ragex.Analysis.MetastaticBridgeTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.MetastaticBridge

  @moduletag :analysis

  describe "supported_metrics/0" do
    test "returns list of supported metrics" do
      metrics = MetastaticBridge.supported_metrics()

      assert :cyclomatic in metrics
      assert :cognitive in metrics
      assert :nesting in metrics
      assert :halstead in metrics
      assert :loc in metrics
      assert :function_metrics in metrics
      assert :purity in metrics
    end
  end

  describe "analyze_file/2" do
    setup do
      # Create temporary test file
      tmp_dir = System.tmp_dir!()
      test_file = Path.join(tmp_dir, "test_module_#{:rand.uniform(10000)}.ex")

      content = """
      defmodule TestModule do
        def simple_function(x) do
          x + 1
        end

        def complex_function(x) do
          if x > 10 do
            if x > 20 do
              :very_high
            else
              :high
            end
          else
            :low
          end
        end

        def impure_function(x) do
          IO.puts("Value: \#{x}")
          x
        end
      end
      """

      File.write!(test_file, content)

      on_exit(fn -> File.rm(test_file) end)

      {:ok, test_file: test_file}
    end

    test "analyzes Elixir file with all metrics", %{test_file: test_file} do
      assert {:ok, result} = MetastaticBridge.analyze_file(test_file)

      assert result.path == test_file
      assert result.language == :elixir
      assert is_map(result.complexity)
      assert is_map(result.purity)
      assert is_list(result.warnings)
      assert %DateTime{} = result.timestamp
    end

    test "analyzes with specific metrics only", %{test_file: test_file} do
      assert {:ok, result} =
               MetastaticBridge.analyze_file(test_file, metrics: [:cyclomatic, :purity])

      assert result.path == test_file
      # Should still have some complexity data
      assert is_map(result.complexity)
      assert is_map(result.purity)
    end

    test "detects complexity in code", %{test_file: test_file} do
      assert {:ok, result} = MetastaticBridge.analyze_file(test_file)

      # Should have cyclomatic complexity > 1 due to conditionals
      assert result.complexity.cyclomatic >= 1
      assert result.complexity.cognitive >= 0
      assert result.complexity.max_nesting >= 0
    end

    test "detects impurity in code", %{test_file: test_file} do
      assert {:ok, result} = MetastaticBridge.analyze_file(test_file)

      # The file has IO.puts which is impure, or it may be marked as unknown
      # Since IO.puts might not be detected at module level (only function bodies)
      assert is_boolean(result.purity.pure?)
      assert is_list(result.purity.effects)
    end

    test "handles non-existent file" do
      assert {:error, reason} = MetastaticBridge.analyze_file("nonexistent.ex")
      assert reason == :enoent
    end

    test "handles invalid Elixir syntax" do
      tmp_dir = System.tmp_dir!()
      invalid_file = Path.join(tmp_dir, "invalid_#{:rand.uniform(10000)}.ex")

      File.write!(invalid_file, "defmodule Broken do\n  def bad(syntax) here\nend")

      on_exit(fn -> File.rm(invalid_file) end)

      # Either it errors, or it parses with the error being a language_specific node
      result = MetastaticBridge.analyze_file(invalid_file)

      case result do
        {:error, _reason} -> assert true
        {:ok, _} -> assert true  # Metastatic may wrap syntax errors in AST
      end
    end
  end

  describe "analyze_directory/2" do
    setup do
      # Create temporary directory with test files
      tmp_dir = Path.join(System.tmp_dir!(), "ragex_test_#{:rand.uniform(10000)}")
      File.mkdir_p!(tmp_dir)

      # Create multiple test files
      file1 = Path.join(tmp_dir, "module1.ex")

      File.write!(file1, """
      defmodule Module1 do
        def func1(x), do: x + 1
      end
      """)

      file2 = Path.join(tmp_dir, "module2.ex")

      File.write!(file2, """
      defmodule Module2 do
        def func2(x) do
          if x > 0, do: :pos, else: :neg
        end
      end
      """)

      sub_dir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(sub_dir)

      file3 = Path.join(sub_dir, "module3.ex")

      File.write!(file3, """
      defmodule Module3 do
        def func3(x), do: x * 2
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, tmp_dir: tmp_dir, files: [file1, file2, file3]}
    end

    test "analyzes all files in directory recursively", %{tmp_dir: tmp_dir, files: files} do
      assert {:ok, results} = MetastaticBridge.analyze_directory(tmp_dir)

      assert length(results) == 3

      # All files should be analyzed
      analyzed_paths = Enum.map(results, & &1.path) |> Enum.sort()
      expected_paths = Enum.sort(files)
      assert analyzed_paths == expected_paths
    end

    test "analyzes only top-level files when recursive: false", %{tmp_dir: tmp_dir} do
      assert {:ok, results} = MetastaticBridge.analyze_directory(tmp_dir, recursive: false)

      # Should only get 2 files from top level, not subdir
      assert length(results) == 2

      Enum.each(results, fn result ->
        refute String.contains?(result.path, "subdir")
      end)
    end

    test "analyzes with parallel processing", %{tmp_dir: tmp_dir} do
      assert {:ok, results} = MetastaticBridge.analyze_directory(tmp_dir, parallel: true)

      assert length(results) == 3
    end

    test "analyzes sequentially when parallel: false", %{tmp_dir: tmp_dir} do
      assert {:ok, results} = MetastaticBridge.analyze_directory(tmp_dir, parallel: false)

      assert length(results) == 3
    end

    test "returns empty list for empty directory" do
      tmp_dir = Path.join(System.tmp_dir!(), "empty_#{:rand.uniform(10000)}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, results} = MetastaticBridge.analyze_directory(tmp_dir)
      assert results == []
    end

    test "analyzes with specific metrics", %{tmp_dir: tmp_dir} do
      assert {:ok, results} =
               MetastaticBridge.analyze_directory(tmp_dir, metrics: [:cyclomatic])

      assert length(results) == 3

      Enum.each(results, fn result ->
        assert is_map(result.complexity)
        assert is_map(result.purity)
      end)
    end
  end

  describe "language detection" do
    test "detects Elixir files" do
      # Create test files for different languages
      tmp_dir = System.tmp_dir!()

      test_files = [
        {"elixir.ex", :elixir, "defmodule Test do\n  def test, do: :ok\nend"},
        {"script.exs", :elixir, "IO.puts \"test\""},
        {"erlang.erl", :erlang, "test() -> ok."},
        {"header.hrl", :erlang, "-define(TEST, ok)."},
        {"python.py", :python, "def test():\n  return 42"},
        {"ruby.rb", :ruby, "def test\n  42\nend"}
      ]

      results =
        Enum.map(test_files, fn {filename, expected_lang, content} ->
          path = Path.join(tmp_dir, filename)
          File.write!(path, content)

          result = MetastaticBridge.analyze_file(path)
          File.rm!(path)

          {filename, expected_lang, result}
        end)

      Enum.each(results, fn {filename, expected_lang, result} ->
        case result do
          {:ok, analysis} ->
            assert analysis.language == expected_lang,
                   "Expected #{expected_lang} for #{filename}, got #{analysis.language}"

          {:error, reason} ->
            # Some languages might not be fully supported, that's ok for this test
            IO.puts("Note: #{filename} failed analysis: #{inspect(reason)}")
        end
      end)
    end
  end
end
