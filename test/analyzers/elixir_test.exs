defmodule Ragex.Analyzers.ElixirTest do
  use ExUnit.Case, async: true

  alias Ragex.Analyzers.Elixir, as: ElixirAnalyzer

  describe "analyze/2" do
    test "extracts module information" do
      source = """
      defmodule TestModule do
        def hello, do: :world
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [module] = result.modules
      assert module.name == TestModule
      assert module.file == "test.ex"
      assert module.line == 1
    end

    test "extracts function information" do
      source = """
      defmodule TestModule do
        def public_function(arg1, arg2) do
          :ok
        end

        defp private_function do
          :private
        end
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert length(result.functions) == 2

      public_func = Enum.find(result.functions, &(&1.name == :public_function))
      assert public_func.arity == 2
      assert public_func.visibility == :public
      assert public_func.module == TestModule

      private_func = Enum.find(result.functions, &(&1.name == :private_function))
      assert private_func.arity == 0
      assert private_func.visibility == :private
    end

    test "extracts import information" do
      source = """
      defmodule TestModule do
        import Enum
        require Logger
        use GenServer
        alias MyApp.Helper
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert length(result.imports) == 4

      assert Enum.any?(result.imports, &(&1.type == :import && &1.to_module == Enum))
      assert Enum.any?(result.imports, &(&1.type == :require && &1.to_module == Logger))
      assert Enum.any?(result.imports, &(&1.type == :use && &1.to_module == GenServer))
      assert Enum.any?(result.imports, &(&1.type == :alias && &1.to_module == MyApp.Helper))
    end

    test "extracts function calls" do
      source = """
      defmodule TestModule do
        def caller do
          String.upcase("test")
        end
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert length(result.calls) >= 1

      call = Enum.find(result.calls, &(&1.to_function == :upcase))
      assert call.to_module == String
      assert call.from_function == :caller
    end

    test "handles syntax errors" do
      source = """
      defmodule TestModule
        def broken
      end
      """

      assert {:error, _} = ElixirAnalyzer.analyze(source, "test.ex")
    end
  end

  describe "supported_extensions/0" do
    test "returns elixir file extensions" do
      assert [".ex", ".exs"] = ElixirAnalyzer.supported_extensions()
    end
  end
end
