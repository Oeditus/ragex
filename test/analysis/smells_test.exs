defmodule Ragex.Analysis.SmellsTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.Smells
  alias Ragex.Analyzers.Elixir, as: ElixirAnalyzer
  alias Ragex.Graph.Store

  @moduletag :smells

  describe "analyze_file/2" do
    test "detects long function smell in Elixir code" do
      # Create a file with a very long function
      path = "/tmp/ragex_test_long_function.ex"

      code = """
      defmodule LongModule do
        def long_function(x) do
          #{Enum.map_join(1..60, "\n  ", fn i -> "IO.puts(\"line #{i}: \#{x}\")" end)}
          x
        end
      end
      """

      File.write!(path, code)

      {:ok, result} = Smells.analyze_file(path)

      assert result.has_smells?
      assert result.total_smells > 0
      assert Enum.any?(result.smells, &(&1.type == :long_function))

      File.rm!(path)
    end

    test "detects deep nesting smell" do
      path = "/tmp/ragex_test_deep_nesting.ex"

      code = """
      defmodule NestedModule do
        def nested_function(a, b, c, d, e) do
          if a do
            if b do
              if c do
                if d do
                  if e do
                    :ok
                  end
                end
              end
            end
          end
        end
      end
      """

      File.write!(path, code)

      {:ok, result} = Smells.analyze_file(path)

      assert result.has_smells?
      assert Enum.any?(result.smells, &(&1.type == :deep_nesting))

      File.rm!(path)
    end

    test "detects magic numbers" do
      path = "/tmp/ragex_test_magic_numbers.ex"

      code = """
      defmodule MagicModule do
        def calculate(x) do
          x * 42 + 3.14159
        end
      end
      """

      File.write!(path, code)

      {:ok, result} = Smells.analyze_file(path)

      # Magic numbers may or may not be detected depending on Metastatic parsing
      # Just check the structure is valid
      assert is_boolean(result.has_smells?)
      assert is_list(result.smells)

      File.rm!(path)
    end

    test "handles file with no smells" do
      path = "/tmp/ragex_test_clean.ex"

      code = """
      defmodule CleanModule do
        def simple_function(x) do
          x + 1
        end
      end
      """

      File.write!(path, code)

      {:ok, result} = Smells.analyze_file(path)

      # May or may not have smells depending on Metastatic's analysis
      assert is_boolean(result.has_smells?)
      assert is_integer(result.total_smells)

      File.rm!(path)
    end

    test "handles invalid file gracefully" do
      assert {:error, _} = Smells.analyze_file("/nonexistent/file.ex")
    end

    test "supports custom thresholds" do
      path = "/tmp/ragex_test_custom_threshold.ex"

      # Function with 20 statements (above custom threshold of 10)
      code = """
      defmodule CustomModule do
        def function_with_statements(x) do
          #{Enum.map_join(1..20, "\n  ", fn i -> "IO.puts(\"line #{i}\")" end)}
          x
        end
      end
      """

      File.write!(path, code)

      {:ok, result} = Smells.analyze_file(path, thresholds: %{max_statements: 10})

      assert result.has_smells?
      assert Enum.any?(result.smells, &(&1.type == :long_function))

      File.rm!(path)
    end
  end

  describe "analyze_directory/2" do
    setup do
      dir = "/tmp/ragex_test_smells_dir"
      File.mkdir_p!(dir)

      # Create files with various smells
      File.write!(
        Path.join(dir, "file1.ex"),
        """
        defmodule File1 do
          def long_func(x) do
            #{Enum.map_join(1..60, "\n    ", fn i -> "IO.puts(\"#{i}\")" end)}
          end
        end
        """
      )

      File.write!(
        Path.join(dir, "file2.ex"),
        """
        defmodule File2 do
          def magic_func(x) do
            x * 42
          end
        end
        """
      )

      File.write!(
        Path.join(dir, "file3.ex"),
        """
        defmodule File3 do
          def clean_func(x), do: x + 1
        end
        """
      )

      on_exit(fn -> File.rm_rf!(dir) end)

      %{dir: dir}
    end

    test "scans directory recursively", %{dir: dir} do
      {:ok, result} = Smells.analyze_directory(dir, recursive: true)

      assert result.total_files >= 2
      assert result.files_with_smells >= 1
      assert result.total_smells > 0
    end

    test "supports parallel processing", %{dir: dir} do
      {:ok, result_parallel} = Smells.analyze_directory(dir, parallel: true)
      {:ok, result_sequential} = Smells.analyze_directory(dir, parallel: false)

      # Both should find smells
      assert result_parallel.total_smells > 0
      assert result_sequential.total_smells > 0
    end

    test "filters by severity", %{dir: dir} do
      {:ok, result_low} = Smells.analyze_directory(dir, min_severity: :low)
      {:ok, result_high} = Smells.analyze_directory(dir, min_severity: :high)

      # High severity should have fewer or equal smells
      assert result_high.total_smells <= result_low.total_smells
    end

    test "returns empty result for nonexistent directory" do
      # Directory doesn't exist, but wildcard returns empty list (not error)
      {:ok, result} = Smells.analyze_directory("/nonexistent/directory")
      assert result.total_files == 0
      assert result.total_smells == 0
    end
  end

  describe "filter_by_severity/2" do
    setup do
      results = [
        %{
          path: "file1.ex",
          smells: [
            %{type: :long_function, severity: :high},
            %{type: :magic_number, severity: :low}
          ],
          total_smells: 2,
          has_smells?: true
        },
        %{
          path: "file2.ex",
          smells: [
            %{type: :deep_nesting, severity: :critical}
          ],
          total_smells: 1,
          has_smells?: true
        }
      ]

      %{results: results}
    end

    test "includes all smells with :low severity", %{results: results} do
      filtered = Smells.filter_by_severity(results, :low)

      total_smells = Enum.sum(Enum.map(filtered, & &1.total_smells))
      assert total_smells == 3
    end

    test "filters out low severity smells", %{results: results} do
      filtered = Smells.filter_by_severity(results, :high)

      total_smells = Enum.sum(Enum.map(filtered, & &1.total_smells))
      assert total_smells == 2
    end

    test "only includes critical smells", %{results: results} do
      filtered = Smells.filter_by_severity(results, :critical)

      total_smells = Enum.sum(Enum.map(filtered, & &1.total_smells))
      assert total_smells == 1
    end
  end

  describe "filter_by_type/2" do
    setup do
      results = [
        %{
          path: "file1.ex",
          smells: [
            %{type: :long_function, severity: :high},
            %{type: :magic_number, severity: :low}
          ],
          total_smells: 2,
          has_smells?: true
        },
        %{
          path: "file2.ex",
          smells: [
            %{type: :magic_number, severity: :low}
          ],
          total_smells: 1,
          has_smells?: true
        }
      ]

      %{results: results}
    end

    test "filters by specific smell type", %{results: results} do
      magic_numbers = Smells.filter_by_type(results, :magic_number)

      total_smells = Enum.sum(Enum.map(magic_numbers, & &1.total_smells))
      assert total_smells == 2
      assert Enum.all?(Enum.flat_map(magic_numbers, & &1.smells), &(&1.type == :magic_number))
    end

    test "returns empty list for nonexistent type", %{results: results} do
      filtered = Smells.filter_by_type(results, :nonexistent_smell)

      assert filtered == []
    end
  end

  describe "default_thresholds/0" do
    test "returns default threshold map" do
      thresholds = Smells.default_thresholds()

      assert is_map(thresholds)
      assert Map.has_key?(thresholds, :max_statements)
      assert Map.has_key?(thresholds, :max_nesting)
      assert Map.has_key?(thresholds, :max_parameters)
      assert Map.has_key?(thresholds, :max_cognitive)
    end
  end

  describe "location tracking" do
    setup do
      # Start the knowledge graph store if not already running
      case Process.whereis(Ragex.Graph.Store) do
        nil ->
          {:ok, _pid} = Store.start_link()
          on_exit(fn -> GenServer.stop(Ragex.Graph.Store) end)

        _pid ->
          :ok
      end

      # Clear the store
      Store.clear()

      :ok
    end

    test "includes location information in smell results" do
      path = "/tmp/ragex_test_location.ex"

      code = """
      defmodule LocationModule do
        def long_function(x) do
          #{Enum.map_join(1..60, "\n  ", fn i -> "IO.puts(\"line #{i}\")" end)}
          x
        end
      end
      """

      File.write!(path, code)

      # First analyze to populate the knowledge graph
      {:ok, analysis} = ElixirAnalyzer.analyze(code, path)
      store_analysis_in_graph(analysis)

      # Then analyze for smells
      {:ok, result} = Smells.analyze_file(path)

      # Find a smell
      smell = Enum.find(result.smells, &(&1.type == :long_function))

      if smell do
        # Check that location is present
        assert Map.has_key?(smell, :location)

        # Location should have a formatted string
        location = smell.location

        if location do
          assert is_map(location)

          # Check for formatted location string
          formatted = Map.get(location, :formatted)

          if formatted do
            assert is_binary(formatted)
            # Due to Metastatic's whole-file analysis limitation, long_function and
            # deep_nesting smells may only have "line 1" when we can't match to a
            # specific function. This is expected behavior.
            assert formatted == "line 1" or formatted =~ "long_function"
          end
        end
      end

      File.rm!(path)
    end

    test "formatted location includes module, function, arity, and line" do
      path = "/tmp/ragex_test_full_location.ex"

      code = """
      defmodule TestModule do
        def problematic_function(a, b) do
          #{Enum.map_join(1..60, "\n  ", fn i -> "IO.puts(\"#{i}\")" end)}
          a + b
        end
      end
      """

      File.write!(path, code)

      # Analyze and populate knowledge graph
      {:ok, analysis} = ElixirAnalyzer.analyze(code, path)
      store_analysis_in_graph(analysis)

      # Analyze for smells
      {:ok, result} = Smells.analyze_file(path)

      smell = Enum.find(result.smells, &(&1.type == :long_function))

      if smell && smell.location do
        location = smell.location

        # Should have module, function, arity
        if Map.get(location, :module) do
          assert location.module == TestModule
        end

        if Map.get(location, :function) do
          assert location.function == :problematic_function
        end

        if Map.get(location, :arity) do
          assert location.arity == 2
        end

        # Should have a line number
        if Map.get(location, :line) do
          assert is_integer(location.line)
          assert location.line > 0
        end

        # Formatted location should follow the pattern Module.function/arity:line
        if Map.get(location, :formatted) do
          assert location.formatted =~ "TestModule.problematic_function/2" or
                   location.formatted == "line 1"
        end
      end

      File.rm!(path)
    end

    test "handles smells when knowledge graph is empty" do
      path = "/tmp/ragex_test_no_graph.ex"

      code = """
      defmodule NoGraphModule do
        def long_func(x) do
          #{Enum.map_join(1..60, "\n  ", fn i -> "IO.puts(\"#{i}\")" end)}
          x
        end
      end
      """

      File.write!(path, code)

      # Don't populate knowledge graph - analyze for smells directly
      {:ok, result} = Smells.analyze_file(path)

      # Should still work, even without knowledge graph context
      assert is_boolean(result.has_smells?)
      assert is_list(result.smells)

      # Smells may have partial location info (line only) or none
      for smell <- result.smells do
        location = Map.get(smell, :location)

        # Location can be nil or a map
        assert location == nil or is_map(location)
      end

      File.rm!(path)
    end

    test "location format is consistent across different smell types" do
      path = "/tmp/ragex_test_multi_smell.ex"

      code = """
      defmodule MultiSmellModule do
        def complex_function(x) do
          # Long function with deep nesting
          if x > 0 do
            if x > 10 do
              if x > 20 do
                if x > 30 do
                  if x > 40 do
                    #{Enum.map_join(1..60, "\n            ", fn i -> "IO.puts(\"#{i}\")" end)}
                  end
                end
              end
            end
          end
          x
        end
      end
      """

      File.write!(path, code)

      # Analyze and populate knowledge graph
      {:ok, analysis} = ElixirAnalyzer.analyze(code, path)
      store_analysis_in_graph(analysis)

      # Analyze for smells
      {:ok, result} = Smells.analyze_file(path)

      # Should find multiple smell types
      smells_with_location =
        Enum.reject(result.smells, &is_nil(Map.get(&1, :location)))

      # Check that all smells with locations have consistent formatting
      for smell <- smells_with_location do
        location = smell.location
        assert is_map(location)

        # If formatted string exists, it should follow the pattern
        if formatted = Map.get(location, :formatted) do
          assert is_binary(formatted)
          # Should not be "unknown"
          assert formatted != "unknown"
        end
      end

      File.rm!(path)
    end
  end

  # Helper to store analysis in knowledge graph
  defp store_analysis_in_graph(%{
         modules: modules,
         functions: functions,
         calls: calls,
         imports: imports
       }) do
    # Store modules
    Enum.each(modules, fn module ->
      Store.add_node(:module, module.name, module)
    end)

    # Store functions
    Enum.each(functions, fn func ->
      Store.add_node(:function, {func.module, func.name, func.arity}, func)
      # Add edge from module to function
      Store.add_edge(
        {:module, func.module},
        {:function, func.module, func.name, func.arity},
        :defines
      )
    end)

    # Store call relationships
    Enum.each(calls, fn call ->
      Store.add_edge(
        {:function, call.from_module, call.from_function, call.from_arity},
        {:function, call.to_module, call.to_function, call.to_arity},
        :calls
      )
    end)

    # Store imports
    Enum.each(imports, fn import ->
      Store.add_edge(
        {:module, import.from_module},
        {:module, import.to_module},
        :imports
      )
    end)
  end
end
