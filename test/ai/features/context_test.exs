defmodule Ragex.AI.Features.ContextTest do
  use ExUnit.Case, async: false

  alias Ragex.AI.Features.Context
  alias Ragex.Graph.Store

  setup do
    # Clear store before each test
    Store.clear()
    :ok
  end

  describe "for_validation_error/4" do
    test "builds context with basic error information" do
      error = %{message: "undefined function test/0", line: 10, column: 5}
      file_path = "lib/test.ex"

      context = Context.for_validation_error(error, file_path)

      assert context.type == :validation_error
      assert context.primary.error == error
      assert context.primary.file_path == file_path
      assert context.primary.language == :elixir
      assert context.primary.error_type == :undefined_reference
    end

    test "detects language from file extension" do
      error = %{message: "error", line: 1, column: 1}

      elixir_context = Context.for_validation_error(error, "test.ex")
      assert elixir_context.primary.language == :elixir

      erlang_context = Context.for_validation_error(error, "test.erl")
      assert erlang_context.primary.language == :erlang

      python_context = Context.for_validation_error(error, "test.py")
      assert python_context.primary.language == :python
    end

    test "classifies error types" do
      syntax_error = %{message: "unexpected token", line: 1, column: 1}
      context = Context.for_validation_error(syntax_error, "test.ex")
      assert context.primary.error_type == :syntax_error

      undefined_error = %{message: "undefined variable", line: 1, column: 1}
      context = Context.for_validation_error(undefined_error, "test.ex")
      assert context.primary.error_type == :undefined_reference

      type_error = %{message: "type mismatch in spec", line: 1, column: 1}
      context = Context.for_validation_error(type_error, "test.ex")
      assert context.primary.error_type == :type_error
    end
  end

  describe "for_refactor_preview/4" do
    test "builds context for rename_function operation" do
      params = %{module: MyModule, old_name: :test, arity: 1}
      affected_files = ["lib/my_module.ex", "test/my_module_test.exs"]

      context = Context.for_refactor_preview(:rename_function, params, affected_files)

      assert context.type == :refactor_preview
      assert context.primary.operation == :rename_function
      assert context.primary.file_count == 2
      assert context.primary.affected_files == affected_files
    end

    test "builds context for rename_module operation" do
      params = %{old_module: OldModule, new_module: NewModule}
      affected_files = ["lib/old_module.ex"]

      context = Context.for_refactor_preview(:rename_module, params, affected_files)

      assert context.type == :refactor_preview
      assert context.primary.operation == :rename_module
    end
  end

  describe "for_dead_code_analysis/2" do
    test "builds context for function analysis" do
      # Add function to store
      Store.add_node(:module, TestModule, %{name: TestModule})
      Store.add_node(:function, {TestModule, :unused, 0}, %{
        name: :unused,
        arity: 0,
        visibility: :private
      })

      function_ref = {:function, TestModule, :unused, 0}
      context = Context.for_dead_code_analysis(function_ref)

      assert context.type == :dead_code_analysis
      assert context.primary.function_ref == function_ref
      assert context.primary.module == TestModule
      assert context.primary.name == :unused
      assert context.primary.arity == 0
      assert context.graph_context.caller_count == 0
    end
  end

  describe "for_duplication_analysis/4" do
    test "builds context for code duplication" do
      code1 = "def test(x), do: x + 1"
      code2 = "def other(y), do: y + 1"
      similarity = 0.85

      context = Context.for_duplication_analysis(code1, code2, similarity)

      assert context.type == :duplication_analysis
      assert context.primary.code1 == code1
      assert context.primary.code2 == code2
      assert context.primary.similarity_score == similarity
    end
  end

  describe "for_dependency_insights/3" do
    test "builds context for module dependencies" do
      Store.add_node(:module, MyModule, %{name: MyModule})
      Store.add_node(:module, OtherModule, %{name: OtherModule})
      Store.add_edge({:module, MyModule}, {:module, OtherModule}, :imports)

      metrics = %{coupling: 0.5, cohesion: 0.8}
      context = Context.for_dependency_insights(MyModule, metrics)

      assert context.type == :dependency_insights
      assert context.primary.module == MyModule
      assert context.primary.metrics == metrics
      assert context.primary.dependency_count == 1
      assert context.primary.dependent_count == 0
    end
  end

  describe "for_complexity_explanation/3" do
    test "builds context for complexity analysis" do
      Store.add_node(:function, {TestModule, :complex, 2}, %{
        name: :complex,
        arity: 2
      })

      function_ref = {:function, TestModule, :complex, 2}
      metrics = %{complexity: 15, cyclomatic_complexity: 10}

      context = Context.for_complexity_explanation(function_ref, metrics)

      assert context.type == :complexity_explanation
      assert context.primary.function_ref == function_ref
      assert context.primary.metrics == metrics
    end
  end

  describe "to_prompt_string/1" do
    test "formats validation error context" do
      error = %{message: "test error", line: 10, column: 5}
      context = Context.for_validation_error(error, "lib/test.ex")

      formatted = Context.to_prompt_string(context)

      assert formatted =~ "Validation Error Context"
      assert formatted =~ "lib/test.ex"
      assert formatted =~ "test error"
      assert formatted =~ "Line 10, Column 5"
    end

    test "formats refactor preview context" do
      params = %{module: MyModule, old_name: :test, arity: 1}
      context = Context.for_refactor_preview(:rename_function, params, ["lib/test.ex"])

      formatted = Context.to_prompt_string(context)

      assert formatted =~ "Refactoring Preview Context"
      assert formatted =~ "rename_function"
      assert formatted =~ "**Files Affected**: 1"
    end

    test "formats dead code analysis context" do
      Store.add_node(:module, TestModule, %{name: TestModule})
      Store.add_node(:function, {TestModule, :unused, 0}, %{
        name: :unused,
        arity: 0,
        visibility: :private
      })

      function_ref = {:function, TestModule, :unused, 0}
      context = Context.for_dead_code_analysis(function_ref)

      formatted = Context.to_prompt_string(context)

      assert formatted =~ "Dead Code Analysis Context"
      assert formatted =~ "TestModule.unused/0"
      assert formatted =~ "**Visibility**: private"
    end

    test "formats duplication analysis context" do
      code1 = "def test(x), do: x + 1"
      code2 = "def other(y), do: y + 1"
      context = Context.for_duplication_analysis(code1, code2, 0.85)

      formatted = Context.to_prompt_string(context)

      assert formatted =~ "Code Duplication Context"
      assert formatted =~ "**Similarity Score**: 0.85"
      assert formatted =~ code1
      assert formatted =~ code2
    end

    test "formats dependency insights context" do
      Store.add_node(:module, MyModule, %{name: MyModule})
      metrics = %{coupling: 0.5, cohesion: 0.8}
      context = Context.for_dependency_insights(MyModule, metrics)

      formatted = Context.to_prompt_string(context)

      assert formatted =~ "Dependency Analysis Context"
      assert formatted =~ "MyModule"
      assert formatted =~ "coupling: 0.5"
      assert formatted =~ "cohesion: 0.8"
    end

    test "formats complexity explanation context" do
      Store.add_node(:function, {TestModule, :complex, 2}, %{
        name: :complex,
        arity: 2
      })

      function_ref = {:function, TestModule, :complex, 2}
      metrics = %{complexity: 15}
      context = Context.for_complexity_explanation(function_ref, metrics)

      formatted = Context.to_prompt_string(context)

      assert formatted =~ "Complexity Analysis Context"
      assert formatted =~ "TestModule.complex/2"
      assert formatted =~ "complexity: 15"
    end
  end
end
