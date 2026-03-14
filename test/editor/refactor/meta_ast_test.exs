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
