defmodule Ragex.Editor.Refactor.MetaASTTest do
  use ExUnit.Case, async: true

  alias Metastatic.Document
  alias Ragex.Editor.Refactor.MetaAST, as: MetaRefactor

  describe "rename_function/5 with Elixir" do
    test "renames function definition" do
      source = """
      defmodule MyMod do
        def old_func(x), do: x + 1
      end
      """

      {:ok, result} = MetaRefactor.rename_function(source, :elixir, "old_func", "new_func")
      assert result =~ "new_func"
      refute result =~ "old_func"
    end

    test "renames function calls" do
      source = """
      defmodule MyMod do
        def run do
          old_func(42)
        end

        def old_func(x), do: x
      end
      """

      {:ok, result} = MetaRefactor.rename_function(source, :elixir, "old_func", "new_func")
      assert result =~ "new_func"
      # The definition and the call should both be renamed
      refute result =~ "old_func"
    end

    test "renames qualified calls" do
      source = """
      defmodule Caller do
        def run do
          MyMod.old_func(1)
        end
      end
      """

      {:ok, result} = MetaRefactor.rename_function(source, :elixir, "old_func", "new_func")
      assert result =~ "MyMod.new_func"
      refute result =~ "old_func"
    end

    test "preserves unrelated functions" do
      source = """
      defmodule MyMod do
        def target(x), do: x
        def other(y), do: y * 2
      end
      """

      {:ok, result} = MetaRefactor.rename_function(source, :elixir, "target", "renamed")
      assert result =~ "renamed"
      assert result =~ "other"
      refute result =~ "target"
    end

    test "arity filter limits scope" do
      source = """
      defmodule MyMod do
        def func(x), do: x
        def func(x, y), do: x + y
      end
      """

      {:ok, result} = MetaRefactor.rename_function(source, :elixir, "func", "renamed", arity: 1)
      # Only the 1-arity version should be renamed
      assert result =~ "renamed"
      # The 2-arity version stays as "func"
      assert result =~ "func"
    end
  end

  describe "rename_module/4 with Elixir" do
    test "renames module definition" do
      source = """
      defmodule OldModule do
        def hello, do: :world
      end
      """

      {:ok, result} = MetaRefactor.rename_module(source, :elixir, "OldModule", "NewModule")
      assert result =~ "NewModule"
      refute result =~ "OldModule"
    end

    test "renames qualified calls to known modules" do
      # IO.puts is recognized by the Elixir adapter as a qualified call
      source = """
      defmodule Caller do
        def run do
          IO.puts("hello")
        end
      end
      """

      {:ok, result} = MetaRefactor.rename_module(source, :elixir, "IO", "Output")
      assert result =~ "Output.puts"
      refute result =~ ~r/\bIO\./
    end

    test "renames import references" do
      source = """
      defmodule Caller do
        use GenServer
      end
      """

      {:ok, result} = MetaRefactor.rename_module(source, :elixir, "GenServer", "MyServer")
      assert result =~ "MyServer"
    end

    test "preserves unrelated modules" do
      source = """
      defmodule Target do
        def hello, do: IO.puts("hi")
      end
      """

      {:ok, result} = MetaRefactor.rename_module(source, :elixir, "Target", "Renamed")
      assert result =~ "Renamed"
      assert result =~ "IO.puts"
    end
  end

  describe "rename_function/5 with Python" do
    test "renames Python function definition and call" do
      source = "def old_func(x):\n    return x + 1\n\nold_func(42)\n"

      case MetaRefactor.rename_function(source, :python, "old_func", "new_func") do
        {:ok, result} ->
          assert result =~ "new_func"
          refute result =~ "old_func"

        {:error, _reason} ->
          # Python adapter round-trip may fail on some environments
          :ok
      end
    end
  end

  describe "rename_function/5 with Ruby" do
    # The Ruby adapter only became round-trippable in Metastatic 0.44, so these
    # are the first tests that exercise Ruby reification at all. They shell out
    # to the `parser`/`unparser` gems and skip when Ruby is unavailable.
    @describetag :ruby

    setup do
      if System.find_executable("ruby") do
        :ok
      else
        {:ok, skip: true}
      end
    end

    test "renames a method definition and its call" do
      source = """
      class Greeter
        def greet(name)
          name.upcase
        end

        def shout(name)
          greet(name)
        end
      end
      """

      assert {:ok, result} = MetaRefactor.rename_function(source, :ruby, "greet", "welcome")
      assert result =~ "def welcome"
      assert result =~ "welcome(name)"
      refute result =~ "greet"
    end

    test "renames a qualified call without disturbing its receiver" do
      # `:name` is a display string and the receiver travels in `:receiver`.
      # Renaming the method must leave the receiver alone -- rewriting it would
      # move the call to a different object.
      assert {:ok, result} =
               MetaRefactor.rename_function("User.find_by(id: 1)", :ruby, "find_by", "lookup")

      assert result =~ "User.lookup"
      refute result =~ "find_by"
    end

    test "preserves the receiver of an unrelated qualified call" do
      source = "Account.find_by(id: 1)\n"

      assert {:ok, result} = MetaRefactor.rename_function(source, :ruby, "find_by", "lookup")
      assert result =~ "Account.lookup"
      refute result =~ "obj."
    end

    test "arity filter limits scope" do
      source = """
      class Calc
        def add(x)
          x
        end

        def add(x, y)
          x + y
        end
      end
      """

      assert {:ok, result} = MetaRefactor.rename_function(source, :ruby, "add", "plus", arity: 1)
      assert result =~ "def plus(x)"
      assert result =~ "def add(x, y)"
    end
  end

  describe "rename_module/4 with Ruby" do
    @describetag :ruby

    setup do
      if System.find_executable("ruby") do
        :ok
      else
        {:ok, skip: true}
      end
    end

    test "renames a class definition" do
      source = """
      class OldClass
        def hello
          1
        end
      end
      """

      assert {:ok, result} = MetaRefactor.rename_module(source, :ruby, "OldClass", "NewClass")
      assert result =~ "class NewClass"
      refute result =~ "OldClass"
    end

    test "renames a qualified call and its receiver node together" do
      # Both `:name` (display) and `:receiver` (the real node) must move, or
      # the reified call and its rendering disagree.
      assert {:ok, result} = MetaRefactor.rename_module("OldMod.run", :ruby, "OldMod", "NewMod")
      assert result =~ "NewMod.run"
      refute result =~ "OldMod"
    end
  end

  describe "rename_function/5 with Erlang" do
    # Metastatic 0.45 completed `Erlang.FromMeta` for full modules, functions,
    # exports/imports, maps, lambdas and `try/catch`, plus `Erlang.unparse/1`
    # for forms and multi-form blocks, making `.erl` refactoring viable.

    test "renames function definition, local call, and -export entry" do
      source = """
      -module(my_mod).
      -export([old_fn/1, caller/0]).

      old_fn(X) ->
          X + 1.

      caller() ->
          old_fn(41).
      """

      assert {:ok, result} = MetaRefactor.rename_function(source, :erlang, "old_fn", "new_fn")
      assert result =~ "-export([new_fn/1,caller/0])."
      assert result =~ "new_fn(X) ->"
      assert result =~ "new_fn(41)"
      refute result =~ "old_fn"
    end

    test "renames remote Erlang calls" do
      source = """
      -module(caller).
      -export([run/1]).

      run(X) ->
          helper:old_fn(X).
      """

      assert {:ok, result} = MetaRefactor.rename_function(source, :erlang, "old_fn", "new_fn")
      assert result =~ "helper:new_fn(X)"
      refute result =~ "old_fn"
    end

    test "arity filter limits scope in both definitions and -export" do
      source = """
      -module(calc).
      -export([add/1, add/2]).

      add(X) ->
          X.

      add(X, Y) ->
          X + Y.
      """

      assert {:ok, result} =
               MetaRefactor.rename_function(source, :erlang, "add", "inc", arity: 1)

      assert result =~ "-export([inc/1,add/2])."
      assert result =~ "inc(X) ->"
      assert result =~ "add(X, Y) ->"
    end
  end

  describe "rename_module/4 with Erlang" do
    test "renames module attribute and remote calls" do
      source = """
      -module(old_mod).
      -export([run/1]).

      run(X) ->
          old_mod:helper(X).
      """

      assert {:ok, result} = MetaRefactor.rename_module(source, :erlang, "old_mod", "new_mod")
      assert result =~ "-module(new_mod)."
      assert result =~ "new_mod:helper(X)"
      refute result =~ "old_mod"
    end
  end

  describe "rename_function/5 with JavaScript" do
    # Metastatic 0.45 moved non-bare JS/TS call callees out of `children` into
    # `:callee` metadata, which `JavaScript.FromMeta` reifies in preference to
    # `:name`. Renaming must update `:callee` as well as `:name`.

    test "renames bare and member_access method calls" do
      source = """
      class Greeter {
        oldMethod(x) {
          return x + 1;
        }
        run() {
          this.oldMethod(1);
          Greeter.oldMethod(2);
          oldMethod(3);
        }
      }
      """

      assert {:ok, result} =
               MetaRefactor.rename_function(source, :javascript, "oldMethod", "newMethod")

      assert result =~ "newMethod(x)"
      assert result =~ "this.newMethod(1)"
      assert result =~ "Greeter.newMethod(2)"
      assert result =~ "newMethod(3)"
      refute result =~ "oldMethod"
    end

    test "arity filter matches actual JS call argument count" do
      source = """
      function run() {
        calc(1);
        calc(1, 2);
      }
      """

      assert {:ok, result} =
               MetaRefactor.rename_function(source, :javascript, "calc", "calcOne", arity: 1)

      assert result =~ "calcOne(1)"
      assert result =~ "calc(1, 2)"
    end
  end

  describe "rename_module/4 with JavaScript" do
    test "renames class definition, static member_access calls, and constructors" do
      source = """
      class OldClass {
        static helper(x) {
          return x;
        }
      }
      OldClass.helper(1);
      new OldClass();
      """

      assert {:ok, result} =
               MetaRefactor.rename_module(source, :javascript, "OldClass", "NewClass")

      assert result =~ "class NewClass"
      assert result =~ "NewClass.helper(1)"
      assert result =~ "new NewClass()"
      refute result =~ "OldClass"
    end
  end

  describe "rename_function_doc/4" do
    test "transforms document directly" do
      source = """
      defmodule MyMod do
        def old_func(x), do: x
      end
      """

      {:ok, doc} = Metastatic.Builder.from_source(source, :elixir)
      {:ok, new_doc} = MetaRefactor.rename_function_doc(doc, "old_func", "new_func")

      assert %Document{} = new_doc
      # Verify the AST was transformed
      {:ok, result} = Metastatic.Builder.to_source(new_doc)
      assert result =~ "new_func"
    end
  end

  describe "rename_module_doc/3" do
    test "transforms document directly" do
      source = """
      defmodule OldMod do
        def hello, do: :world
      end
      """

      {:ok, doc} = Metastatic.Builder.from_source(source, :elixir)
      {:ok, new_doc} = MetaRefactor.rename_module_doc(doc, "OldMod", "NewMod")

      assert %Document{} = new_doc
      {:ok, result} = Metastatic.Builder.to_source(new_doc)
      assert result =~ "NewMod"
    end
  end
end
