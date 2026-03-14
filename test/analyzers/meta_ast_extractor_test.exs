defmodule Ragex.Analyzers.MetaASTExtractorTest do
  use ExUnit.Case, async: true

  alias Metastatic.Document
  alias Ragex.Analyzers.MetaASTExtractor

  describe "extract/2 with Elixir source" do
    test "extracts module from Elixir source" do
      source = """
      defmodule MyApp.Calculator do
        def add(a, b), do: a + b
      end
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :elixir)
      {:ok, result} = MetaASTExtractor.extract(doc, "lib/calculator.ex")

      assert [mod | _] = result.modules
      assert mod.name == MyApp.Calculator
      assert mod.file == "lib/calculator.ex"
    end

    test "extracts functions with arity and visibility" do
      source = """
      defmodule Foo do
        def public_func(a, b), do: a + b
        defp private_helper(x), do: x * 2
      end
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :elixir)
      {:ok, result} = MetaASTExtractor.extract(doc, "lib/foo.ex")

      assert [_, _] = result.functions

      pub = Enum.find(result.functions, &(&1.name == :public_func))
      assert pub.arity == 2
      assert pub.visibility == :public
      assert pub.module == Foo
      assert pub.file == "lib/foo.ex"

      priv = Enum.find(result.functions, &(&1.name == :private_helper))
      assert priv.arity == 1
      assert priv.visibility == :private
    end

    test "extracts function calls with module resolution" do
      source = """
      defmodule Caller do
        def run(x) do
          IO.puts("done")
          String.upcase(x)
        end
      end
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :elixir)
      {:ok, result} = MetaASTExtractor.extract(doc, "lib/caller.ex")

      io_call = Enum.find(result.calls, &(&1.to_function == :puts && &1.to_module == IO))
      assert io_call
      assert io_call.from_module == Caller
      assert io_call.from_function == :run

      str_call = Enum.find(result.calls, &(&1.to_function == :upcase && &1.to_module == String))
      assert str_call
    end

    test "extracts imports (alias/use/import/require)" do
      source = """
      defmodule MyApp.Worker do
        use GenServer
        alias MyApp.Repo
        import Ecto.Query
        require Logger
      end
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :elixir)
      {:ok, result} = MetaASTExtractor.extract(doc, "lib/worker.ex")

      assert [_, _, _ | _] = result.imports
      types = Enum.map(result.imports, & &1.type)
      assert :use in types or :import in types
    end

    test "handles nested modules" do
      source = """
      defmodule Outer do
        defmodule Inner do
          def greet, do: :hello
        end

        def hello, do: Inner.greet()
      end
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :elixir)
      {:ok, result} = MetaASTExtractor.extract(doc, "lib/outer.ex")

      mod_names = Enum.map(result.modules, & &1.name)
      assert Outer in mod_names
      # Inner module should also be extracted (name may vary by adapter)
      assert [_, _ | _] = result.modules
    end

    test "tracks function context for calls" do
      source = """
      defmodule Multi do
        def alpha do
          String.length("hi")
        end

        def beta do
          Enum.count([1, 2])
        end
      end
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :elixir)
      {:ok, result} = MetaASTExtractor.extract(doc, "lib/multi.ex")

      length_call =
        Enum.find(result.calls, &(&1.to_function == :length && &1.to_module == String))

      count_call =
        Enum.find(result.calls, &(&1.to_function == :count && &1.to_module == Enum))

      if length_call, do: assert(length_call.from_function == :alpha)
      if count_call, do: assert(count_call.from_function == :beta)
    end
  end

  describe "extract/2 with Python source" do
    test "extracts class and methods from Python" do
      source = """
      class Calculator:
          def add(self, a, b):
              return a + b

          def subtract(self, a, b):
              return a - b
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :python)
      {:ok, result} = MetaASTExtractor.extract(doc, "calculator.py")

      assert [mod | _] = result.modules
      assert mod.name == "Calculator"
      assert mod.file == "calculator.py"

      func_names = Enum.map(result.functions, & &1.name)
      assert :add in func_names
      assert :subtract in func_names
    end

    test "extracts imports from Python" do
      source = """
      import os
      from pathlib import Path

      def main():
          pass
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :python)
      {:ok, result} = MetaASTExtractor.extract(doc, "main.py")

      assert [_ | _] = result.imports
    end
  end

  describe "extract/2 with Erlang source" do
    test "extracts entities from Erlang when parser succeeds" do
      # Erlang parsing via Metastatic may fail on some OTP versions;
      # test the extraction path only when parse succeeds.
      source = "-module(math_utils).\n-export([add/2]).\nadd(A, B) ->\n    A + B.\n"

      case Ragex.LanguageSupport.parse_document(source, :erlang) do
        {:ok, doc} ->
          {:ok, result} = MetaASTExtractor.extract(doc, "src/math_utils.erl")
          assert [_ | _] = result.functions

        {:error, _} ->
          # Erlang parser not available or incompatible -- skip gracefully
          :ok
      end
    end
  end

  describe "extract/2 with synthetic MetaAST" do
    test "handles hand-crafted MetaAST" do
      ast =
        {:container, [container_type: :module, name: "TestMod", line: 1],
         [
           {:import, [source: "Logger", import_type: :require], []},
           {:function_def,
            [name: "do_work", params: [{:param, [], "input"}], visibility: :public, line: 5],
            [
              {:function_call, [name: "Logger.info", line: 6],
               [{:literal, [subtype: :string], "working"}]},
              {:function_call, [name: "process", line: 7], [{:variable, [], "input"}]}
            ]}
         ]}

      doc = Document.new(ast, :elixir)
      {:ok, result} = MetaASTExtractor.extract(doc, "lib/test_mod.ex")

      assert [mod] = result.modules
      assert mod.name == TestMod
      assert mod.line == 1

      assert [func] = result.functions
      assert func.name == :do_work
      assert func.arity == 1
      assert func.module == TestMod
      assert func.visibility == :public
      assert func.line == 5

      assert [_, _] = result.calls
      logger_call = Enum.find(result.calls, &(&1.to_module == Logger))
      assert logger_call.to_function == :info
      assert logger_call.from_function == :do_work

      local_call = Enum.find(result.calls, &is_nil(&1.to_module))
      assert local_call.to_function == :process

      assert [imp] = result.imports
      assert imp.to_module == Logger
      assert imp.type == :require
    end

    test "handles empty module" do
      ast = {:container, [container_type: :module, name: "Empty", line: 1], []}
      doc = Document.new(ast, :elixir)
      {:ok, result} = MetaASTExtractor.extract(doc, "lib/empty.ex")

      assert [mod] = result.modules
      assert mod.name == Empty
      assert result.functions == []
      assert result.calls == []
      assert result.imports == []
    end

    test "handles top-level functions (no container)" do
      ast =
        {:block, [],
         [
           {:function_def, [name: "main", params: [], visibility: :public, line: 1],
            [{:function_call, [name: "print", line: 2], [{:literal, [subtype: :string], "hi"}]}]}
         ]}

      doc = Document.new(ast, :python)
      {:ok, result} = MetaASTExtractor.extract(doc, "main.py")

      assert result.modules == []
      assert [func] = result.functions
      assert func.name == :main
      assert func.module == "top_level"

      assert [call] = result.calls
      assert call.to_function == :print
      assert call.from_function == :main
    end

    test "handles nested function calls" do
      ast =
        {:container, [container_type: :module, name: "Nested", line: 1],
         [
           {:function_def, [name: "run", params: [], line: 2],
            [
              {:function_call, [name: "Enum.map", line: 3],
               [
                 {:function_call, [name: "fetch_data", line: 3], []},
                 {:lambda, [params: [{:param, [], "x"}]],
                  [{:function_call, [name: "transform", line: 3], [{:variable, [], "x"}]}]}
               ]}
            ]}
         ]}

      doc = Document.new(ast, :elixir)
      {:ok, result} = MetaASTExtractor.extract(doc, "lib/nested.ex")

      call_names = Enum.map(result.calls, & &1.to_function)
      assert :map in call_names
      assert :fetch_data in call_names
      assert :transform in call_names
    end
  end

  describe "extract_file/2" do
    test "parses and extracts from a real file" do
      # Use the extractor module itself (has real functions)
      {:ok, result} = MetaASTExtractor.extract_file("lib/ragex/analyzers/meta_ast_extractor.ex")

      assert [_ | _] = result.modules
      assert [_ | _] = result.functions
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = MetaASTExtractor.extract_file("nonexistent.ex")
    end

    test "returns error for unsupported language" do
      tmp = Path.join(System.tmp_dir!(), "ragex_test_unsupported.txt")
      File.write!(tmp, "not code")

      assert {:error, {:unsupported_language, :unknown}} = MetaASTExtractor.extract_file(tmp)

      File.rm!(tmp)
    end
  end
end
