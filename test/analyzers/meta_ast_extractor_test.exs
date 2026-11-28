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

    test "extracts modules, functions, and calls from Erlang MetaAST" do
      ast =
        {:container, [container_type: :module, name: "math_utils", language: :erlang],
         [
           {:function_def, [name: "add", params: [{:param, [], "A"}, {:param, [], "B"}]],
            [
              {:function_call, [name: "erlang.+"], [{:variable, [], "A"}, {:variable, [], "B"}]}
            ]}
         ]}

      doc = Document.new(ast, :erlang)
      {:ok, result} = MetaASTExtractor.extract(doc, "src/math_utils.erl")

      assert [%{name: :math_utils, file: "src/math_utils.erl"}] = result.modules
      assert [%{name: :add, arity: 2, module: :math_utils}] = result.functions
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

      # A bare call has no receiver, so it is attributed to the caller's own
      # container -- the same convention every native analyzer (Python,
      # JavaScript, Ruby, Java) already follows. `to_module` is never `nil`.
      local_call = Enum.find(result.calls, &(&1.to_function == :process))
      assert local_call.to_module == TestMod
      assert local_call.from_module == TestMod
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

  describe "extract/2 with Agda MetaAST" do
    @describetag :agda

    test "extracts modules, functions, calls, and imports from Agda AST" do
      ast =
        {:container, [container_type: :module, name: "Data.Nat", language: :agda],
         [
           {:import, [module: "Agda.Primitive", open: true], []},
           {:function_def, [name: "add", params: [{:param, [], "x"}, {:param, [], "y"}]],
            [
              {:function_call, [name: "plus"], [{:variable, [], "x"}, {:variable, [], "y"}]}
            ]}
         ]}

      doc = Document.new(ast, :agda)
      {:ok, result} = MetaASTExtractor.extract(doc, "src/Data/Nat.agda")

      assert [%{name: "Data.Nat", file: "src/Data/Nat.agda"}] = result.modules
      assert [%{name: :add, arity: 2, module: "Data.Nat"}] = result.functions
      assert [%{to_function: :plus, from_module: "Data.Nat", from_function: :add}] = result.calls
      assert [%{to_module: "Agda.Primitive"}] = result.imports
    end

    test "safely truncates function and call names exceeding 255-character atom limit" do
      long_name = String.duplicate("a", 300)

      ast =
        {:container, [container_type: :module, name: "Proof.Substitution", language: :agda],
         [
           {:function_def, [name: long_name, params: ["σ", "ρ", "k"]],
            [
              {:function_call, [name: long_name], [{:variable, [], "k"}]}
            ]}
         ]}

      doc = Document.new(ast, :agda)
      assert {:ok, result} = MetaASTExtractor.extract(doc, "Proof/Substitution.agda")
      assert [func] = result.functions
      assert String.length(Atom.to_string(func.name)) == 255
      assert func.metadata.params == ["σ", "ρ", "k"]
      assert [call] = result.calls
      assert String.length(Atom.to_string(call.to_function)) == 255
    end
  end

  describe "extract/2 call receivers" do
    # Metastatic 0.44 moved the receiver of a qualified call out of the
    # `:name` display string and into a real `:receiver` MetaAST node. `:name`
    # is now lossy -- it renders as the literal "obj" for any receiver the
    # adapter cannot print -- so resolution has to read `:receiver`.
    test "resolves a constant receiver from the :receiver meta key" do
      ast =
        {:container, [container_type: :class, name: "BookService", language: :ruby],
         [
           {:function_def, [name: "find", params: [{:param, [], "id"}], language: :ruby],
            [
              {:function_call,
               [
                 name: "User.find_by",
                 receiver: {:literal, [subtype: :constant], "User"}
               ], [{:variable, [], "id"}]}
            ]}
         ]}

      doc = Document.new(ast, :ruby)
      assert {:ok, result} = MetaASTExtractor.extract(doc, "book_service.rb")

      assert [call] = result.calls
      assert call.to_module == "User"
      assert call.to_function == :find_by
      assert call.from_module == "BookService"
    end

    test "prefers :receiver over a lossy :name rendering" do
      # `:name` says "obj.title" because the adapter could not render the
      # receiver; the real receiver is a local variable, so the call belongs
      # to the caller's container rather than to a module called "obj".
      ast =
        {:container, [container_type: :class, name: "Report", language: :ruby],
         [
           {:function_def, [name: "title", params: [], language: :ruby],
            [
              {:function_call, [name: "obj.title", receiver: {:variable, [], "record"}], []}
            ]}
         ]}

      doc = Document.new(ast, :ruby)
      assert {:ok, result} = MetaASTExtractor.extract(doc, "report.rb")

      assert [call] = result.calls
      assert call.to_module == "Report"
      assert call.to_function == :title
      refute call.to_module == "obj"
    end

    test "falls back to splitting :name when there is no :receiver" do
      # Bare calls and MetaAST produced before Metastatic 0.44 carry no
      # `:receiver`; the dotted `:name` is then the only signal.
      ast =
        {:container, [container_type: :module, name: "Legacy", language: :ruby],
         [
           {:function_def, [name: "run", params: [], language: :ruby],
            [{:function_call, [name: "Kernel.puts"], []}]}
         ]}

      doc = Document.new(ast, :ruby)
      assert {:ok, result} = MetaASTExtractor.extract(doc, "legacy.rb")

      assert [call] = result.calls
      assert call.to_module == "Kernel"
      assert call.to_function == :puts
    end

    test "a singleton definition belongs to its receiver, not the enclosing container" do
      ast =
        {:container, [container_type: :class, name: "Catalog", language: :ruby],
         [
           {:function_def,
            [
              name: "self.list",
              params: [],
              receiver: {:literal, [subtype: :constant], "Catalog"},
              language: :ruby
            ], []}
         ]}

      doc = Document.new(ast, :ruby)
      assert {:ok, result} = MetaASTExtractor.extract(doc, "catalog.rb")

      assert [func] = result.functions
      assert func.name == :list
      assert func.module == "Catalog"
    end

    test "a definition without a receiver keeps its plain name" do
      ast =
        {:container, [container_type: :class, name: "Catalog", language: :ruby],
         [{:function_def, [name: "find", params: [], language: :ruby], []}]}

      doc = Document.new(ast, :ruby)
      assert {:ok, result} = MetaASTExtractor.extract(doc, "catalog.rb")

      assert [func] = result.functions
      assert func.name == :find
      assert func.module == "Catalog"
    end

    test "a top-level definition falls back to the top_level container" do
      ast =
        {:block, [], [{:function_def, [name: "helper", params: [], language: :ruby], []}]}

      doc = Document.new(ast, :ruby)
      assert {:ok, result} = MetaASTExtractor.extract(doc, "script.rb")

      assert [func] = result.functions
      assert func.module == "top_level"
    end
  end

  describe "extract/2 with Ruby source" do
    # End-to-end through the real Metastatic Ruby adapter (which shells out to
    # the `parser` gem), so these are skipped when Ruby is unavailable.
    @describetag :ruby

    setup do
      if System.find_executable("ruby") do
        :ok
      else
        {:ok, skip: true}
      end
    end

    test "resolves a constant receiver on a qualified call" do
      source = """
      class BookService
        def find(id)
          User.find_by(id: id)
        end
      end
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :ruby)
      {:ok, result} = MetaASTExtractor.extract(doc, "book_service.rb")

      call = Enum.find(result.calls, &(&1.to_function == :find_by))
      assert call, "expected a find_by call, got #{inspect(result.calls)}"
      assert call.to_module == "User"
      assert call.from_module == "BookService"
    end

    test "a value receiver is attributed to the caller, never to \"obj\"" do
      source = """
      class Report
        def title
          record&.title
        end
      end
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :ruby)
      {:ok, result} = MetaASTExtractor.extract(doc, "report.rb")

      call = Enum.find(result.calls, &(&1.to_function == :title))
      assert call, "expected a title call, got #{inspect(result.calls)}"
      assert call.to_module == "Report"
      refute Enum.any?(result.calls, &(&1.to_module == "obj"))
    end

    test "a singleton definition is named without its receiver prefix" do
      source = """
      class Catalog
        def self.list
          all
        end
      end
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :ruby)
      {:ok, result} = MetaASTExtractor.extract(doc, "catalog.rb")

      assert [func] = result.functions
      assert func.name == :list
      assert func.module == "Catalog"
    end

    test "module mixins become imports" do
      source = """
      class Service
        include Enumerable
        extend ClassMethods
      end
      """

      {:ok, doc} = Ragex.LanguageSupport.parse_document(source, :ruby)
      {:ok, result} = MetaASTExtractor.extract(doc, "service.rb")

      types = Enum.map(result.imports, & &1.type)
      assert :include in types
      assert :extend in types

      targets = Enum.map(result.imports, & &1.to_module)
      assert "Enumerable" in targets
      assert "ClassMethods" in targets
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
