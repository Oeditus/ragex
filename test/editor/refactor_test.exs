defmodule Ragex.Editor.RefactorTest do
  # Graph.Store is shared state
  use ExUnit.Case, async: false

  alias Ragex.Editor.Refactor
  alias Ragex.Editor.Refactor.Elixir, as: ElixirRefactor
  alias Ragex.Graph.Store

  setup do
    # Use a test-specific directory for temporary files
    test_dir = Path.join(System.tmp_dir!(), "ragex_refactor_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    %{test_dir: test_dir}
  end

  describe "Elixir.rename_function/4" do
    test "renames simple function definition" do
      content = """
      defmodule Test do
        def old_func(x) do
          x + 1
        end
      end
      """

      assert {:ok, new_content} = ElixirRefactor.rename_function(content, :old_func, :new_func, 1)
      assert new_content =~ "def new_func(x)"
      refute new_content =~ "def old_func"
    end

    test "renames function calls" do
      content = """
      defmodule Test do
        def func do
          old_func(42)
        end

        def old_func(x), do: x
      end
      """

      assert {:ok, new_content} = ElixirRefactor.rename_function(content, :old_func, :new_func, 1)
      assert new_content =~ "new_func(42)"
      assert new_content =~ "def new_func(x)"
    end

    test "renames module-qualified calls" do
      content = """
      defmodule Test do
        def caller do
          OtherModule.old_func(10)
        end
      end
      """

      assert {:ok, new_content} = ElixirRefactor.rename_function(content, :old_func, :new_func, 1)
      assert new_content =~ "OtherModule.new_func(10)"
    end

    test "renames private functions" do
      content = """
      defmodule Test do
        defp old_private(x), do: x * 2

        def caller, do: old_private(5)
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.rename_function(content, :old_private, :new_private, 1)

      assert new_content =~ "defp new_private(x)"
      assert new_content =~ "new_private(5)"
    end

    test "renames function references" do
      content = """
      defmodule Test do
        def old_func(x), do: x

        def get_func, do: &old_func/1
      end
      """

      assert {:ok, new_content} = ElixirRefactor.rename_function(content, :old_func, :new_func, 1)
      assert new_content =~ "&new_func/1"
    end

    test "respects arity - only renames matching arity" do
      content = """
      defmodule Test do
        def old_func(x), do: x
        def old_func(x, y), do: x + y

        def caller do
          old_func(1)
          old_func(1, 2)
        end
      end
      """

      # Rename only /1 version
      assert {:ok, new_content} = ElixirRefactor.rename_function(content, :old_func, :new_func, 1)
      assert new_content =~ "def new_func(x)"
      assert new_content =~ "def old_func(x, y)"
      assert new_content =~ "new_func(1)"
      assert new_content =~ "old_func(1, 2)"
    end

    test "renames all arities when arity is nil" do
      content = """
      defmodule Test do
        def old_func(x), do: x
        def old_func(x, y), do: x + y
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.rename_function(content, :old_func, :new_func, nil)

      assert new_content =~ "def new_func(x)"
      assert new_content =~ "def new_func(x, y)"
      refute new_content =~ "old_func"
    end

    test "handles parse errors gracefully" do
      invalid_content = "def func("

      assert {:error, message} =
               ElixirRefactor.rename_function(invalid_content, :func, :new_func, 0)

      assert message =~ "Parse error"
    end
  end

  describe "Elixir.rename_module/3" do
    test "renames module definition" do
      content = """
      defmodule OldModule do
        def func, do: :ok
      end
      """

      assert {:ok, new_content} = ElixirRefactor.rename_module(content, :OldModule, :NewModule)
      assert new_content =~ "defmodule NewModule"
      refute new_content =~ "OldModule"
    end

    test "renames module references" do
      content = """
      defmodule Test do
        alias OldModule

        def func do
          OldModule.call()
        end
      end
      """

      assert {:ok, new_content} = ElixirRefactor.rename_module(content, :OldModule, :NewModule)
      assert new_content =~ "alias NewModule"
      assert new_content =~ "NewModule.call()"
    end

    test "renames nested module names" do
      content = """
      defmodule Parent.OldModule do
        def func, do: :ok
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.rename_module(content, :"Parent.OldModule", :"Parent.NewModule")

      assert new_content =~ "defmodule Parent.NewModule"
    end
  end

  describe "Elixir.find_function_calls/3" do
    test "finds all call sites" do
      content = """
      defmodule Test do
        def caller1, do: target(1)
        def caller2, do: target(2)
        def caller3, do: OtherModule.target(3)

        def target(x), do: x
      end
      """

      assert {:ok, lines} = ElixirRefactor.find_function_calls(content, :target, 1)
      # 3 calls + 1 definition = 4 total
      assert length(lines) == 4
    end

    test "respects arity" do
      content = """
      defmodule Test do
        def caller do
          func(1)
          func(1, 2)
        end
      end
      """

      assert {:ok, lines} = ElixirRefactor.find_function_calls(content, :func, 1)
      assert length(lines) == 1

      assert {:ok, lines} = ElixirRefactor.find_function_calls(content, :func, 2)
      assert length(lines) == 1
    end
  end

  describe "Refactor.rename_function/5 integration" do
    setup %{test_dir: dir} do
      # Clear the graph before each test
      Store.clear()

      # Create test files with a simple module
      module_file = Path.join(dir, "test_module.ex")

      module_content = """
      defmodule TestModule do
        def old_function(x) do
          x * 2
        end

        def another_function do
          old_function(10)
        end
      end
      """

      File.write!(module_file, module_content)

      caller_file = Path.join(dir, "caller.ex")

      caller_content = """
      defmodule Caller do
        def call_it do
          TestModule.old_function(5)
        end
      end
      """

      File.write!(caller_file, caller_content)

      # Analyze and store in graph
      {:ok, module_analysis} =
        Ragex.Analyzers.Elixir.analyze(module_content, module_file)

      store_analysis(module_analysis)

      {:ok, caller_analysis} =
        Ragex.Analyzers.Elixir.analyze(caller_content, caller_file)

      store_analysis(caller_analysis)

      %{module_file: module_file, caller_file: caller_file}
    end

    @tag :skip
    test "renames function across multiple files", %{
      module_file: module_file,
      caller_file: caller_file
    } do
      # Rename TestModule.old_function/1 to TestModule.new_function/1
      assert {:ok, result} =
               Refactor.rename_function(:TestModule, :old_function, :new_function, 1)

      assert result.status == :success
      assert result.files_modified == 2

      # Check module file was updated
      module_new_content = File.read!(module_file)
      assert module_new_content =~ "def new_function(x)"
      assert module_new_content =~ "new_function(10)"
      refute module_new_content =~ "old_function"

      # Check caller file was updated
      caller_new_content = File.read!(caller_file)
      assert caller_new_content =~ "TestModule.new_function(5)"
      refute caller_new_content =~ "old_function"
    end

    @tag :skip
    test "scope: :module only renames within the same module", %{module_file: module_file} do
      assert {:ok, result} =
               Refactor.rename_function(:TestModule, :old_function, :new_function, 1,
                 scope: :module
               )

      assert result.status == :success
      # Only the module file itself should be modified
      assert result.files_modified == 1

      module_new_content = File.read!(module_file)
      assert module_new_content =~ "def new_function(x)"
    end

    test "fails for non-existent function" do
      assert {:error, message} =
               Refactor.rename_function(:TestModule, :nonexistent, :new_name, 1)

      assert message =~ "not found in graph"
    end

    @tag :skip
    test "validation catches syntax errors during refactor" do
      # This test would require creating a scenario where refactoring produces invalid code
      # For now, we'll test that validation is enabled by default
      assert {:ok, result} =
               Refactor.rename_function(:TestModule, :old_function, :valid_new_name, 1)

      assert result.status == :success
      # Validation was performed (it's in transaction options by default)
    end
  end

  describe "Refactor.rename_module/3 integration" do
    setup %{test_dir: dir} do
      # Clear the graph before each test
      Store.clear()

      module_file = Path.join(dir, "old_mod.ex")

      module_content = """
      defmodule OldMod do
        def func, do: :ok
      end
      """

      File.write!(module_file, module_content)

      # Analyze and store
      {:ok, analysis} = Ragex.Analyzers.Elixir.analyze(module_content, module_file)
      store_analysis(analysis)

      %{module_file: module_file}
    end

    @tag :skip
    test "renames module definition", %{module_file: module_file} do
      assert {:ok, result} = Refactor.rename_module(:OldMod, :NewMod)

      assert result.status == :success
      assert result.files_modified >= 1

      new_content = File.read!(module_file)
      assert new_content =~ "defmodule NewMod"
      refute new_content =~ "OldMod"
    end

    test "fails for non-existent module" do
      assert {:error, message} = Refactor.rename_module(:NonExistent, :NewName)
      assert message =~ "not found in graph"
    end
  end

  # Helper to store analysis in graph
  defp store_analysis(%{modules: modules, functions: functions, calls: calls}) do
    Enum.each(modules, fn module ->
      Store.add_node(:module, module.name, module)
    end)

    Enum.each(functions, fn func ->
      Store.add_node(:function, {func.module, func.name, func.arity}, func)

      Store.add_edge(
        {:module, func.module},
        {:function, func.module, func.name, func.arity},
        :defines
      )
    end)

    Enum.each(calls, fn call ->
      Store.add_edge(
        {:function, call.from_module, call.from_function, call.from_arity},
        {:function, call.to_module, call.to_function, call.to_arity},
        :calls
      )
    end)
  end
end
