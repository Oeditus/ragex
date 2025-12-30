defmodule Ragex.Embeddings.TextGeneratorTest do
  use ExUnit.Case, async: true

  alias Ragex.Embeddings.TextGenerator

  describe "module_text/1" do
    test "generates text for module with full data" do
      module_data = %{
        name: :MyModule,
        file: "lib/my_module.ex",
        line: 1,
        doc: "This is a test module",
        metadata: %{type: :module}
      }

      text = TextGenerator.module_text(module_data)

      assert text =~ "Module: MyModule"
      assert text =~ "Documentation: This is a test module"
      assert text =~ "File: lib/my_module.ex"
      assert text =~ "Type: module"
    end

    test "generates text for module without documentation" do
      module_data = %{
        name: :SimpleModule,
        file: "lib/simple.ex",
        line: 1,
        metadata: %{}
      }

      text = TextGenerator.module_text(module_data)

      assert text =~ "Module: SimpleModule"
      assert text =~ "File: lib/simple.ex"
      refute text =~ "Documentation"
    end
  end

  describe "function_text/1" do
    test "generates text for function with full data" do
      function_data = %{
        name: :calculate,
        arity: 2,
        module: :Math,
        file: "lib/math.ex",
        line: 10,
        doc: "Calculates something",
        visibility: :public
      }

      text = TextGenerator.function_text(function_data)

      assert text =~ "Function: calculate/2"
      assert text =~ "Module: Math"
      assert text =~ "Documentation: Calculates something"
      assert text =~ "Visibility: public"
      assert text =~ "File: lib/math.ex:10"
    end

    test "generates text for private function" do
      function_data = %{
        name: :_helper,
        arity: 1,
        module: :MyModule,
        file: "lib/my.ex",
        line: 20,
        visibility: :private
      }

      text = TextGenerator.function_text(function_data)

      assert text =~ "Function: _helper/1"
      assert text =~ "Visibility: private"
    end
  end

  describe "function_with_code_text/2" do
    test "includes code snippet" do
      function_data = %{
        name: :hello,
        arity: 0,
        module: :Greeter,
        file: "lib/greeter.ex",
        line: 5,
        visibility: :public
      }

      code = "def hello do\n  \"Hello, world!\"\nend"

      text = TextGenerator.function_with_code_text(function_data, code)

      assert text =~ "Function: hello/0"
      assert text =~ "Code: def hello"
    end

    test "truncates very long code" do
      function_data = %{
        name: :big,
        arity: 0,
        module: :Large,
        file: "lib/large.ex",
        line: 1,
        visibility: :public
      }

      # Create code longer than 1000 chars
      code = String.duplicate("x", 1500)

      text = TextGenerator.function_with_code_text(function_data, code)

      # Should be truncated
      assert String.length(text) < 1200
    end

    test "handles nil code" do
      function_data = %{
        name: :test,
        arity: 0,
        module: :Test,
        file: "lib/test.ex",
        line: 1,
        visibility: :public
      }

      text = TextGenerator.function_with_code_text(function_data, nil)

      refute text =~ "Code:"
    end
  end

  describe "call_text/1" do
    test "generates text for function call" do
      call_data = %{
        from_module: :Caller,
        from_function: :main,
        from_arity: 0,
        to_module: :Callee,
        to_function: :helper,
        to_arity: 2
      }

      text = TextGenerator.call_text(call_data)

      assert text =~ "Function call:"
      assert text =~ "Caller.main/0"
      assert text =~ "Callee.helper/2"
      assert text =~ "calls"
    end
  end

  describe "import_text/1" do
    test "generates text for import" do
      import_data = %{
        from_module: :"Elixir.MyApp.Module",
        to_module: :Logger
      }

      text = TextGenerator.import_text(import_data)

      assert text =~ "Import:"
      assert text =~ "MyApp.Module"
      assert text =~ "Logger"
      assert text =~ "imports"
    end
  end
end
