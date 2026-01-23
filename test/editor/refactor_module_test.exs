defmodule Ragex.Editor.RefactorModuleTest do
  use ExUnit.Case, async: false

  alias Ragex.Editor.Refactor
  alias Ragex.Editor.Refactor.Elixir, as: ElixirRefactor
  alias Ragex.Graph.Store

  setup do
    test_dir = Path.join(System.tmp_dir!(), "ragex_module_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(test_dir)
    Store.clear()

    on_exit(fn ->
      File.rm_rf!(test_dir)
      Store.clear()
    end)

    %{test_dir: test_dir}
  end

  describe "move_function/5" do
    @tag skip: true, reason: :phase_10a
    test "moves function to existing module", %{test_dir: dir} do
      source_file = Path.join(dir, "source.ex")
      target_file = Path.join(dir, "target.ex")

      source_content = """
      defmodule Source do
        def keep_func, do: :kept

        def move_me(x), do: x * 2
      end
      """

      target_content = """
      defmodule Target do
        def existing_func, do: :exists
      end
      """

      File.write!(source_file, source_content)
      File.write!(target_file, target_content)

      # Analyze both files
      {:ok, source_analysis} = Ragex.Analyzers.Elixir.analyze(source_content, source_file)
      {:ok, target_analysis} = Ragex.Analyzers.Elixir.analyze(target_content, target_file)

      store_analysis(source_analysis)
      store_analysis(target_analysis)

      assert {:ok, result} =
               Refactor.move_function(:Source, :Target, :move_me, 1, validate: false)

      assert result.status == :success
      assert length(result.files_modified) == 2

      # Check source file
      new_source = File.read!(source_file)
      assert new_source =~ "keep_func"
      refute new_source =~ "move_me"

      # Check target file
      new_target = File.read!(target_file)
      assert new_target =~ "existing_func"
      assert new_target =~ "def move_me(x), do: x * 2"
    end

    @tag skip: true, reason: :phase_10a
    test "moves function to new module", %{test_dir: dir} do
      source_file = Path.join(dir, "source.ex")

      source_content = """
      defmodule Source do
        def helper(x), do: x + 1
      end
      """

      File.write!(source_file, source_content)

      {:ok, analysis} = Ragex.Analyzers.Elixir.analyze(source_content, source_file)
      store_analysis(analysis)

      # Move to new module
      assert {:ok, result} =
               Refactor.move_function(:Source, :NewTarget, :helper, 1, validate: false)

      assert result.status == :success

      # New module file should be created
      new_target_file = Path.join(dir, "new_target.ex")
      assert File.exists?(new_target_file)

      new_target = File.read!(new_target_file)
      assert new_target =~ "defmodule NewTarget"
      assert new_target =~ "def helper(x), do: x + 1"
    end

    @tag skip: true, reason: :phase_10a
    test "updates references after move", %{test_dir: dir} do
      source_file = Path.join(dir, "source.ex")
      caller_file = Path.join(dir, "caller.ex")

      source_content = """
      defmodule Source do
        def utility(x), do: x * 2
      end
      """

      caller_content = """
      defmodule Caller do
        def use_it, do: Source.utility(5)
      end
      """

      File.write!(source_file, source_content)
      File.write!(caller_file, caller_content)

      {:ok, source_analysis} = Ragex.Analyzers.Elixir.analyze(source_content, source_file)
      {:ok, caller_analysis} = Ragex.Analyzers.Elixir.analyze(caller_content, caller_file)

      store_analysis(source_analysis)
      store_analysis(caller_analysis)

      assert {:ok, _result} =
               Refactor.move_function(:Source, :Target, :utility, 1, validate: false)

      # Caller should be updated
      new_caller = File.read!(caller_file)
      assert new_caller =~ "Target.utility(5)"
      refute new_caller =~ "Source.utility"
    end
  end

  describe "extract_module/4" do
    @tag skip: true, reason: :phase_10a
    test "extracts multiple functions to new module", %{test_dir: dir} do
      source_file = Path.join(dir, "big_module.ex")

      source_content = """
      defmodule BigModule do
        def keep_this, do: :kept

        def helper1(x), do: x + 1
        def helper2(x), do: x * 2
        def helper3(x), do: x - 1
      end
      """

      File.write!(source_file, source_content)

      {:ok, analysis} = Ragex.Analyzers.Elixir.analyze(source_content, source_file)
      store_analysis(analysis)

      # Extract helpers to new module
      functions = [{:helper1, 1}, {:helper2, 1}, {:helper3, 1}]

      assert {:ok, result} =
               Refactor.extract_module(:BigModule, :"BigModule.Helpers", functions,
                 validate: false
               )

      assert result.status == :success

      # Source should have only keep_this
      new_source = File.read!(source_file)
      assert new_source =~ "keep_this"
      refute new_source =~ "helper1"
      refute new_source =~ "helper2"
      refute new_source =~ "helper3"

      # New module file should exist
      helpers_file = Path.join(dir, "big_module/helpers.ex")
      assert File.exists?(helpers_file)

      helpers_content = File.read!(helpers_file)
      assert helpers_content =~ "defmodule BigModule.Helpers"
      assert helpers_content =~ "def helper1"
      assert helpers_content =~ "def helper2"
      assert helpers_content =~ "def helper3"
    end

    @tag skip: true, reason: :phase_10a
    test "adds alias to source module", %{test_dir: dir} do
      source_file = Path.join(dir, "source.ex")

      source_content = """
      defmodule Source do
        def main do
          helper(10)
        end

        def helper(x), do: x * 2
      end
      """

      File.write!(source_file, source_content)

      {:ok, analysis} = Ragex.Analyzers.Elixir.analyze(source_content, source_file)
      store_analysis(analysis)

      assert {:ok, _result} =
               Refactor.extract_module(:Source, :"Source.Utils", [{:helper, 1}], validate: false)

      # Source should have alias
      new_source = File.read!(source_file)
      assert new_source =~ "alias Source.Utils" or new_source =~ "Source.Utils.helper"
    end

    @tag skip: true, reason: :phase_10a
    test "updates calls in other files", %{test_dir: dir} do
      source_file = Path.join(dir, "source.ex")
      caller_file = Path.join(dir, "caller.ex")

      source_content = """
      defmodule Source do
        def utility(x), do: x + 1
      end
      """

      caller_content = """
      defmodule Caller do
        def use_utility, do: Source.utility(5)
      end
      """

      File.write!(source_file, source_content)
      File.write!(caller_file, caller_content)

      {:ok, source_analysis} = Ragex.Analyzers.Elixir.analyze(source_content, source_file)
      {:ok, caller_analysis} = Ragex.Analyzers.Elixir.analyze(caller_content, caller_file)

      store_analysis(source_analysis)
      store_analysis(caller_analysis)

      assert {:ok, _result} =
               Refactor.extract_module(:Source, :"Source.Utils", [{:utility, 1}], validate: false)

      # Caller should reference new module
      new_caller = File.read!(caller_file)
      assert new_caller =~ "Source.Utils.utility(5)"
    end

    @tag skip: true, reason: :phase_10a
    test "handles empty source module after extraction", %{test_dir: dir} do
      source_file = Path.join(dir, "source.ex")

      source_content = """
      defmodule Source do
        def only_func(x), do: x
      end
      """

      File.write!(source_file, source_content)

      {:ok, analysis} = Ragex.Analyzers.Elixir.analyze(source_content, source_file)
      store_analysis(analysis)

      assert {:ok, _result} =
               Refactor.extract_module(:Source, :Extracted, [{:only_func, 1}], validate: false)

      # Source module should be empty but valid
      new_source = File.read!(source_file)
      assert new_source =~ "defmodule Source"
      refute new_source =~ "only_func"
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
