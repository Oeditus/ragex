defmodule Ragex.Editor.ValidatorsTest do
  use ExUnit.Case, async: true

  alias Ragex.Editor.Validator
  alias Ragex.Editor.Validators.Elixir, as: ElixirValidator
  alias Ragex.Editor.Validators.{Erlang, Python, Javascript}

  describe "Ragex.Editor.Validator" do
    test "detects Elixir files" do
      assert {:ok, :valid} = Validator.validate("defmodule Test, do: :ok", path: "test.ex")
      assert {:ok, :valid} = Validator.validate("defmodule Test, do: :ok", path: "test.exs")
    end

    test "detects Erlang files" do
      assert {:ok, :valid} = Validator.validate("-module(test).", path: "test.erl")
    end

    test "detects Python files" do
      # Only run if Python is available
      case System.cmd("python3", ["--version"], stderr_to_stdout: true) do
        {_, 0} ->
          assert {:ok, :valid} = Validator.validate("x = 1", path: "test.py")

        _ ->
          # Python not available, expect warning
          assert {:error, [error]} = Validator.validate("x = 1", path: "test.py")
          assert error.severity == :warning
      end
    end

    test "detects JavaScript files" do
      # Only run if Node is available
      case System.cmd("node", ["--version"], stderr_to_stdout: true) do
        {_, 0} ->
          assert {:ok, :valid} = Validator.validate("const x = 1;", path: "test.js")

        _ ->
          # Node not available, expect warning
          assert {:error, [error]} = Validator.validate("const x = 1;", path: "test.js")
          assert error.severity == :warning
      end
    end

    test "returns :no_validator for unknown file types" do
      assert {:ok, :no_validator} = Validator.validate("content", path: "test.txt")
    end

    test "accepts explicit language option" do
      assert {:ok, :valid} = Validator.validate("defmodule Test, do: :ok", language: :elixir)
    end

    test "accepts explicit validator option" do
      assert {:ok, :valid} =
               Validator.validate("defmodule Test, do: :ok", validator: ElixirValidator)
    end
  end

  describe "Ragex.Editor.Validators.Elixir" do
    test "validates correct Elixir code" do
      code = """
      defmodule Test do
        def hello, do: :world
      end
      """

      assert {:ok, :valid} = ElixirValidator.validate(code)
    end

    test "detects syntax errors" do
      code = """
      defmodule Test do
        def hello do
          # Missing end
      end
      """

      assert {:error, [error]} = ElixirValidator.validate(code)
      assert error.message =~ ~r/(unexpected|missing|end)/i
      assert error.line
    end

    test "detects missing closing parenthesis" do
      code = "IO.puts(\"hello\""

      assert {:error, [error]} = ElixirValidator.validate(code)
      assert error.message =~ ~r/(unexpected|missing|\(|\))/i
    end

    test "can_validate? returns true for .ex and .exs files" do
      assert ElixirValidator.can_validate?("test.ex")
      assert ElixirValidator.can_validate?("test.exs")
      refute ElixirValidator.can_validate?("test.erl")
      refute ElixirValidator.can_validate?("test.py")
    end
  end

  describe "Ragex.Editor.Validators.Erlang" do
    test "validates correct Erlang code" do
      code = """
      -module(test).
      -export([hello/0]).

      hello() -> world.
      """

      assert {:ok, :valid} = Erlang.validate(code)
    end

    test "detects syntax errors" do
      code = """
      -module(test).
      hello() -> world
      """

      # Missing period at end or other syntax issues
      assert {:error, [error]} = Erlang.validate(code)
      assert error.message
    end

    test "detects incomplete forms" do
      code = "-module(test)"

      assert {:error, [error]} = Erlang.validate(code)
      assert error.message
    end

    test "can_validate? returns true for .erl and .hrl files" do
      assert Erlang.can_validate?("test.erl")
      assert Erlang.can_validate?("test.hrl")
      refute Erlang.can_validate?("test.ex")
      refute Erlang.can_validate?("test.py")
    end
  end

  describe "Ragex.Editor.Validators.Python" do
    setup do
      # Check if Python is available
      case System.cmd("python3", ["--version"], stderr_to_stdout: true) do
        {_, 0} -> {:ok, python_available: true}
        _ -> {:ok, python_available: false}
      end
    end

    test "validates correct Python code", %{python_available: available} do
      if available do
        code = """
        def hello():
            return "world"
        """

        assert {:ok, :valid} = Python.validate(code)
      else
        # Skip test if Python not available
        :ok
      end
    end

    test "detects syntax errors", %{python_available: available} do
      if available do
        code = """
        def hello()
            return "world"
        """

        assert {:error, [error]} = Python.validate(code)
        assert error.message =~ ~r/(syntax|expected)/i
        assert error.line
      else
        # Should return warning about Python not found
        assert {:error, [error]} = Python.validate("code")
        assert error.severity == :warning
      end
    end

    test "detects indentation errors", %{python_available: available} do
      if available do
        code = """
        def hello():
        return "world"
        """

        assert {:error, [error]} = Python.validate(code)
        assert error.message =~ ~r/(indent|expected)/i
      else
        :ok
      end
    end

    test "can_validate? returns true for .py files" do
      assert Python.can_validate?("test.py")
      refute Python.can_validate?("test.ex")
      refute Python.can_validate?("test.js")
    end
  end

  describe "Ragex.Editor.Validators.Javascript" do
    setup do
      # Check if Node is available
      case System.cmd("node", ["--version"], stderr_to_stdout: true) do
        {_, 0} -> {:ok, node_available: true}
        _ -> {:ok, node_available: false}
      end
    end

    test "validates correct JavaScript code", %{node_available: available} do
      if available do
        code = """
        function hello() {
          return "world";
        }
        """

        assert {:ok, :valid} = Javascript.validate(code)
      else
        :ok
      end
    end

    test "detects syntax errors", %{node_available: available} do
      if available do
        code = """
        function hello() {
          return "world"
        """

        assert {:error, [error]} = Javascript.validate(code)
        assert error.message
        assert error.line
      else
        # Should return warning about Node not found
        assert {:error, [error]} = Javascript.validate("code")
        assert error.severity == :warning
      end
    end

    test "detects unexpected tokens", %{node_available: available} do
      if available do
        code = "const x = ;"

        assert {:error, [error]} = Javascript.validate(code)
        assert error.message =~ ~r/(unexpected|token)/i
      else
        :ok
      end
    end

    test "can_validate? returns true for JavaScript file extensions" do
      assert Javascript.can_validate?("test.js")
      assert Javascript.can_validate?("test.jsx")
      assert Javascript.can_validate?("test.ts")
      assert Javascript.can_validate?("test.tsx")
      assert Javascript.can_validate?("test.mjs")
      assert Javascript.can_validate?("test.cjs")
      refute Javascript.can_validate?("test.ex")
      refute Javascript.can_validate?("test.py")
    end
  end
end
