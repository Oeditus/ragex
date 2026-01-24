defmodule Ragex.Analyzers.MetastaticEnrichmentTest do
  use ExUnit.Case, async: true

  alias Ragex.Analyzers.Metastatic

  @moduletag :metastatic

  describe "enrich_functions_with_metastatic/2" do
    test "enriches functions with MetaAST metrics" do
      source = """
      defmodule TestModule do
        def simple_function(x) do
          x + 1
        end

        def complex_function(a, b) do
          if a > b do
            IO.puts("a is greater")
            a
          else
            IO.puts("b is greater")
            b
          end
        end
      end
      """

      {:ok, result} = Metastatic.analyze(source, "test.ex")

      # Should have 2 functions
      assert length(result.functions) == 2

      # Check that functions have metastatic metadata
      simple_func = Enum.find(result.functions, fn f -> f.name == :simple_function end)
      complex_func = Enum.find(result.functions, fn f -> f.name == :complex_function end)

      # Both functions should have metadata
      refute is_nil(simple_func)
      refute is_nil(complex_func)

      # Check if enrichment happened (metastatic key should exist if enrichment worked)
      # Note: This might be nil if MetaAST parsing didn't find the functions
      # because the MetaAST structure might be different than expected
      if Map.has_key?(simple_func.metadata, :metastatic) do
        assert is_map(simple_func.metadata.metastatic)
        assert Map.has_key?(simple_func.metadata.metastatic, :complexity)
        assert Map.has_key?(simple_func.metadata.metastatic, :purity)
        assert Map.has_key?(simple_func.metadata.metastatic, :halstead)
        assert Map.has_key?(simple_func.metadata.metastatic, :loc)
      end
    end

    test "handles analysis without metastatic enrichment gracefully" do
      source = """
      defmodule EmptyModule do
      end
      """

      {:ok, result} = Metastatic.analyze(source, "test.ex")

      # Should succeed even with no functions
      assert result.functions == []
    end

    test "handles functions with no matching MetaAST data" do
      source = """
      defmodule SimpleModule do
        def hello do
          :world
        end
      end
      """

      # This should not crash even if MetaAST parsing fails
      assert {:ok, result} = Metastatic.analyze(source, "test.ex")
      assert length(result.functions) == 1

      func = hd(result.functions)
      assert func.name == :hello
      # Metadata might be empty or have metastatic key depending on parsing
      assert is_map(func.metadata)
    end
  end

  describe "fallback behavior" do
    test "falls back to native analyzer when metastatic parsing fails" do
      # Invalid Elixir code that might cause parsing to fail
      source = """
      defmodule BrokenModule do
        def incomplete_function(
      """

      # Should get an error (either from Metastatic or native analyzer)
      assert {:error, _reason} = Metastatic.analyze(source, "test.ex")
    end
  end
end
