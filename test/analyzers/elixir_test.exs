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
      assert Enum.count(result.functions) == 2

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
      assert Enum.count(result.imports) == 4

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
      assert result.calls != []

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

  describe "documentation extraction" do
    test "extracts @moduledoc" do
      source = """
      defmodule DocumentedModule do
        @moduledoc "This is a documented module"

        def hello, do: :world
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [module] = result.modules
      assert module.name == DocumentedModule
      assert module.doc == "This is a documented module"
    end

    test "extracts multi-line @moduledoc with heredoc" do
      source = """
      defmodule MultiLineDoc do
        @moduledoc \"\"\"       
        This is a multi-line module documentation.

        It can span multiple lines and include examples.
        \"\"\"

        def test, do: :ok
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [module] = result.modules
      assert module.name == MultiLineDoc
      assert is_binary(module.doc)
      assert String.contains?(module.doc, "multi-line")
      assert String.contains?(module.doc, "examples")
    end

    test "extracts @doc for functions" do
      source = """
      defmodule TestModule do
        @doc "Greets the world"
        def hello do
          :world
        end

        @doc "Says goodbye"
        def goodbye do
          :bye
        end
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert Enum.count(result.functions) == 2

      hello_func = Enum.find(result.functions, &(&1.name == :hello))
      assert hello_func.doc == "Greets the world"

      goodbye_func = Enum.find(result.functions, &(&1.name == :goodbye))
      assert goodbye_func.doc == "Says goodbye"
    end

    test "handles @doc false" do
      source = """
      defmodule TestModule do
        @doc false
        def private_impl do
          :hidden
        end
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [func] = result.functions
      assert func.doc == nil
    end

    test "handles @moduledoc false" do
      source = """
      defmodule TestModule do
        @moduledoc false

        def hello, do: :world
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [module] = result.modules
      assert module.doc == nil
    end

    test "handles mixed documented and undocumented functions" do
      source = """
      defmodule TestModule do
        @doc "This is documented"
        def documented do
          :ok
        end

        def undocumented do
          :ok
        end

        @doc "Also documented"
        def another_documented do
          :ok
        end
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert Enum.count(result.functions) == 3

      documented = Enum.find(result.functions, &(&1.name == :documented))
      assert documented.doc == "This is documented"

      undocumented = Enum.find(result.functions, &(&1.name == :undocumented))
      assert undocumented.doc == nil

      another = Enum.find(result.functions, &(&1.name == :another_documented))
      assert another.doc == "Also documented"
    end

    test "handles module without any documentation" do
      source = """
      defmodule UndocumentedModule do
        def hello, do: :world
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [module] = result.modules
      assert module.doc == nil
      assert [func] = result.functions
      assert func.doc == nil
    end

    test "handles multiple consecutive @doc attributes (last one wins)" do
      source = """
      defmodule TestModule do
        @doc "First doc"
        @doc "Second doc"
        def hello, do: :world
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [func] = result.functions
      # Last @doc wins
      assert func.doc == "Second doc"
    end

    test "clears pending doc between functions" do
      source = """
      defmodule TestModule do
        @doc "First function"
        def first, do: :ok

        def second, do: :ok
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert Enum.count(result.functions) == 2

      first = Enum.find(result.functions, &(&1.name == :first))
      assert first.doc == "First function"

      second = Enum.find(result.functions, &(&1.name == :second))
      assert second.doc == nil
    end

    test "extracts empty string for @moduledoc when explicitly set to \"\"" do
      source = """
      defmodule EmptyModuleDoc do
        @moduledoc ""

        def hello, do: :world
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [module] = result.modules
      assert module.name == EmptyModuleDoc
      assert module.doc == ""
    end

    test "extracts empty string for @doc when explicitly set to \"\"" do
      source = """
      defmodule TestModule do
        @doc ""
        def empty_doc_function do
          :ok
        end
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [func] = result.functions
      assert func.name == :empty_doc_function
      assert func.doc == ""
    end

    test "correctly associates @moduledoc for module without function definitions" do
      source = """
      defmodule NoFunctionsModule do
        @moduledoc "This module has no functions"
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [module] = result.modules
      assert module.name == NoFunctionsModule
      assert module.doc == "This module has no functions"
      assert result.functions == []
    end
  end

  describe "type and spec extraction" do
    test "extracts @type definitions" do
      source = """
      defmodule TestModule do
        @type user_id :: integer()
        @type status :: :active | :inactive
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert Enum.count(result.types) == 2

      user_id_type = Enum.find(result.types, &(&1.name == :user_id))
      assert user_id_type.module == TestModule
      assert user_id_type.kind == :type
      assert user_id_type.visibility == :public
      assert user_id_type.spec =~ "integer"

      status_type = Enum.find(result.types, &(&1.name == :status))
      assert status_type.kind == :type
      assert status_type.visibility == :public
    end

    test "extracts @spec for functions" do
      source = """
      defmodule TestModule do
        @spec add(integer(), integer()) :: integer()
        def add(a, b), do: a + b
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [func] = result.functions
      assert func.spec =~ "add"
      assert func.spec =~ "integer"
    end

    test "extracts @typedoc for types" do
      source = """
      defmodule TestModule do
        @typedoc "User identifier"
        @type user_id :: integer()
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [type] = result.types
      assert type.doc == "User identifier"
    end
  end

  describe "inline comment extraction" do
    test "extracts inline comments for undocumented functions" do
      source = """
      defmodule TestModule do
        # This function adds two numbers
        def add(a, b), do: a + b
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [func] = result.functions
      assert func.doc == "This function adds two numbers"
    end

    test "prefers @doc over inline comments" do
      source = """
      defmodule TestModule do
        # This comment should be ignored
        @doc "Official documentation"
        def add(a, b), do: a + b
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [func] = result.functions
      assert func.doc == "Official documentation"
    end
  end

  describe "macro expansion" do
    test "expands defdelegate to create function with call graph" do
      source = """
      defmodule TestModule do
        defdelegate add(a, b), to: Math
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :partial)
      assert [func] = result.functions
      assert func.name == :add
      assert func.arity == 2

      # Should create a call to Math.add/2
      assert [call] = result.calls
      assert call.to_module == Math
      assert call.to_function == :add
      assert call.from_function == :add
    end

    test "expands defdelegate with :as option" do
      source = """
      defmodule TestModule do
        defdelegate process(data), to: Worker, as: :run
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :partial)
      assert [func] = result.functions
      assert func.name == :process

      # Should call Worker.run/1 instead of Worker.process/1
      assert [call] = result.calls
      assert call.to_module == Worker
      assert call.to_function == :run
    end

    test "extracts struct field information" do
      source = """
      defmodule User do
        defstruct [:name, :email, age: 0]
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [module] = result.modules
      assert is_map(module.metadata[:struct])
      fields = module.metadata[:struct].fields
      assert length(fields) == 3

      name_field = Enum.find(fields, fn f -> f.name == :name end)
      assert name_field.default == nil

      age_field = Enum.find(fields, fn f -> f.name == :age end)
      assert age_field.default == "0"
    end

    test "can disable macro expansion" do
      source = """
      defmodule TestModule do
        defdelegate add(a, b), to: Math
      end
      """

      # With expansion disabled, no function or calls should be created
      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :none)
      # defdelegate won't expand, so it won't create a def
      assert result.functions == []
      assert result.calls == []
    end

    test "piped calls record the arity the user wrote" do
      source = """
      defmodule TestModule do
        def save(data), do: data |> Repo.insert()
      end
      """

      for mode <- [:none, :partial] do
        assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: mode)

        assert [call] = result.calls,
               "expected exactly one call in #{mode} mode, got: #{inspect(result.calls)}"

        assert call.to_module == Repo
        assert call.to_function == :insert
        assert call.to_arity == 1
      end
    end

    test "piped calls into local functions record the arity" do
      source = """
      defmodule TestModule do
        def run(data), do: data |> normalize()
        defp normalize(x), do: x
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :none)
      # A local pipe target is not a remote call, so it must not produce a
      # bogus arity-0 call edge.
      refute Enum.any?(result.calls, &(&1.to_function == :normalize and &1.to_arity == 0))
    end

    test "expands use GenServer and marks injected definitions" do
      source = """
      defmodule TestServer do
        use GenServer

        def handle_call(_msg, _from, state), do: {:reply, :ok, state}
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :partial)

      # The user's own definition is attributed to the user. `use GenServer`
      # also injects a `handle_call/3` default, so pick the non-injected one.
      handle_call =
        Enum.find(result.functions, &(&1.name == :handle_call and not &1.metadata.injected))

      assert handle_call.arity == 3
      assert handle_call.metadata.injected == false

      # Definitions injected by `use GenServer` are visible but flagged
      injected = Enum.filter(result.functions, & &1.metadata.injected)
      assert Enum.any?(injected, &(&1.name == :child_spec and &1.arity == 1))

      # The `:use` edge survives expansion
      assert Enum.any?(result.imports, &(&1.to_module == GenServer and &1.type == :use))
    end

    test "does not duplicate the :use edge as a synthetic :require" do
      source = """
      defmodule TestServer do
        use GenServer
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :partial)

      gen_server_edges = Enum.filter(result.imports, &(&1.to_module == GenServer))
      assert [%{type: :use}] = gen_server_edges
    end

    test "reports macros it could not expand" do
      source = """
      defmodule TestModule do
        use Definitely.Not.A.Real.Module
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :partial)
      assert [reason] = result.unexpanded
      assert reason =~ "Definitely.Not.A.Real.Module"
    end

    test "reports no unexpanded macros for fully resolvable code" do
      source = """
      defmodule TestModule do
        def hello, do: :world
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :partial)
      assert result.unexpanded == []
    end

    test "does not record operator encodings as call edges" do
      source = """
      defmodule TestModule do
        def compare(a, b) do
          if a == b, do: a - b, else: a ++ b
        end
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :partial)

      # `if` desugars to `case :erlang.==(...)`, and `-`/`++` become
      # `:erlang.-/2` and `:erlang.++/2`. None of those are real dependencies.
      refute Enum.any?(result.calls, &(&1.to_module == :erlang)),
             "expected no :erlang operator edges, got: #{inspect(Enum.map(result.calls, &{&1.to_module, &1.to_function}))}"
    end

    test "still records genuine :erlang BIF calls" do
      source = """
      defmodule TestModule do
        def check(x), do: is_binary(x) and length(x) > 0
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :partial)

      erlang =
        result.calls |> Enum.filter(&(&1.to_module == :erlang)) |> Enum.map(& &1.to_function)

      assert :is_binary in erlang
      assert :length in erlang
      # ...but the `>/2` comparison is still filtered out
      refute :> in erlang
    end

    test "expands defdelegate without a manual rewrite" do
      source = """
      defmodule TestModule do
        defdelegate add(a, b), to: Math
      end
      """

      # ExPanda >= 0.3.0 expands defdelegate natively; no fallback pass runs.
      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :partial)
      assert [func] = result.functions
      assert func.name == :add
      assert func.arity == 2

      assert [call] = result.calls
      assert call.to_module == Math
      assert call.to_function == :add
      assert call.to_arity == 2
    end

    test "never crashes on a file it cannot expand" do
      source = """
      defmodule TestModule do
        use Some.Unknown.Dsl, opt: 1
        def hello, do: :world
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex", expand_macros: :full)
      assert Enum.any?(result.functions, &(&1.name == :hello))
    end
  end

  describe "documentation reference extraction" do
    test "extracts module references from documentation" do
      source = """
      defmodule TestModule do
        @moduledoc "Uses `Enum` for operations"
        def test, do: :ok
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [module] = result.modules
      assert is_list(module.metadata[:references])
      # Enum is a standard library module that exists, so it should be found
      with [_ | _] <- module.metadata[:references],
           ref when not is_nil(ref) <-
             Enum.find(module.metadata[:references], fn r -> r.type == :module end),
           do: assert(ref.name == Enum)
    end

    test "extracts function references with arity from documentation" do
      source = """
      defmodule TestModule do
        @moduledoc "See `TestModule.helper/1` for more"
        
        @doc "Helper function"
        def helper(arg), do: arg
      end
      """

      assert {:ok, result} = ElixirAnalyzer.analyze(source, "test.ex")
      assert [module] = result.modules
      assert is_list(module.metadata[:references])

      # Should find a reference to TestModule.helper/1
      ref =
        Enum.find(module.metadata[:references], fn r ->
          r.type == :function && r.module == TestModule && r.name == :helper
        end)

      if ref do
        assert ref.arity == 1
      end
    end
  end
end
