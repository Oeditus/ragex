defmodule Ragex.Editor.RefactorInlineTest do
  use ExUnit.Case, async: true

  alias Ragex.Editor.Refactor.Elixir, as: ElixirRefactor

  describe "inline_function/4" do
    test "inlines simple function" do
      content = """
      defmodule Test do
        def caller do
          helper(5)
        end

        defp helper(x), do: x * 2
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.inline_function(content, :Test, :helper, 1)

      # Function call should be replaced with body
      assert new_content =~ "5 * 2"
      # Function definition should be removed
      refute new_content =~ "defp helper"
    end

    test "inlines function with multiple calls" do
      content = """
      defmodule Test do
        def caller1, do: helper(1)
        def caller2, do: helper(2)
        def caller3, do: helper(3)

        defp helper(x), do: x + 10
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.inline_function(content, :Test, :helper, 1)

      assert new_content =~ "1 + 10"
      assert new_content =~ "2 + 10"
      assert new_content =~ "3 + 10"
      refute new_content =~ "defp helper"
    end

    test "inlines function with parameter substitution" do
      content = """
      defmodule Test do
        def process do
          compute(5, 10)
        end

        defp compute(a, b) do
          a * b + a
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.inline_function(content, :Test, :compute, 2)

      # Should substitute parameters correctly
      assert new_content =~ "5 * 10 + 5"
      refute new_content =~ "defp compute"
    end

    test "handles qualified module calls" do
      content = """
      defmodule Test do
        def caller do
          OtherModule.helper(42)
        end
        
        defp helper(x), do: x
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.inline_function(content, :Test, :helper, 1)

      # Should NOT inline qualified calls to other modules
      assert new_content =~ "OtherModule.helper(42)"
      # But should remove the local helper definition
      refute new_content =~ "defp helper"
    end

    test "fails for multi-clause functions" do
      content = """
      defmodule Test do
        defp helper(0), do: :zero
        defp helper(n), do: n * 2
      end
      """

      assert {:error, message} =
               ElixirRefactor.inline_function(content, :Test, :helper, 1)

      assert message =~ "multi-clause"
    end

    test "inlines function with complex body" do
      content = """
      defmodule Test do
        def caller do
          process(10)
        end

        defp process(x) do
          y = x * 2
          z = y + 5
          {:ok, z}
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.inline_function(content, :Test, :process, 1)

      refute new_content =~ "defp process"
    end
  end

  describe "convert_visibility/5" do
    test "converts public to private" do
      content = """
      defmodule Test do
        def public_func(x), do: x * 2
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.convert_visibility(content, :Test, :public_func, 1, :private)

      assert new_content =~ "defp public_func(x)"
      refute new_content =~ "def public_func"
    end

    test "converts private to public" do
      content = """
      defmodule Test do
        defp private_func(x), do: x + 1
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.convert_visibility(content, :Test, :private_func, 1, :public)

      assert new_content =~ "def private_func(x)"
      refute new_content =~ "defp private_func"
    end

    test "respects arity" do
      content = """
      defmodule Test do
        def func(x), do: x
        def func(x, y), do: x + y
      end
      """

      # Only convert /1 version
      assert {:ok, new_content} =
               ElixirRefactor.convert_visibility(content, :Test, :func, 1, :private)

      assert new_content =~ "defp func(x)"
      assert new_content =~ "def func(x, y)"
    end

    test "converts multi-clause functions" do
      content = """
      defmodule Test do
        def func(0), do: :zero
        def func(n), do: n
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.convert_visibility(content, :Test, :func, 1, :private)

      assert new_content =~ "defp func(0)"
      assert new_content =~ "defp func(n)"
    end

    test "converts defmacro to defmacrop" do
      content = """
      defmodule Test do
        defmacro my_macro(x) do
          quote do: unquote(x) * 2
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.convert_visibility(content, :Test, :my_macro, 1, :private)

      assert new_content =~ "defmacrop my_macro(x)"
    end
  end

  describe "rename_parameter/6" do
    test "renames parameter in function head" do
      content = """
      defmodule Test do
        def func(old_param) do
          old_param * 2
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.rename_parameter(content, :Test, :func, 1, "old_param", "new_param")

      assert new_content =~ "func(new_param)"
      assert new_content =~ "new_param * 2"
      refute new_content =~ "old_param"
    end

    test "renames parameter in multiple clauses" do
      content = """
      defmodule Test do
        def func(param) when is_integer(param) do
          param * 2
        end

        def func(param) when is_binary(param) do
          String.length(param)
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.rename_parameter(content, :Test, :func, 1, "param", "input")

      # Check both clauses renamed
      assert new_content =~ "func(input) when is_integer(input)"
      assert new_content =~ "func(input) when is_binary(input)"
      assert new_content =~ "input * 2"
      assert new_content =~ "String.length(input)"
    end

    test "renames parameter with pattern matching" do
      content = """
      defmodule Test do
        def process({:ok, value}) do
          value * 2
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.rename_parameter(content, :Test, :process, 1, "value", "result")

      assert new_content =~ "{:ok, result}"
      assert new_content =~ "result * 2"
    end

    test "renames only specified arity" do
      content = """
      defmodule Test do
        def func(x), do: x
        def func(x, y), do: x + y
      end
      """

      # Rename parameter in /2 version
      assert {:ok, new_content} =
               ElixirRefactor.rename_parameter(content, :Test, :func, 2, "x", "first")

      # func/1 should remain unchanged (x not renamed)
      assert new_content =~ "func(x)"
      # x is still returned
      assert new_content =~ ~r/x\s*$/m
      # func/2 should have parameter renamed to first
      assert new_content =~ "func(first, y)"
      assert new_content =~ "first + y"
    end

    test "handles parameter with default value" do
      content = """
      defmodule Test do
        def func(opts \\\\ []) do
          Keyword.get(opts, :key)
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.rename_parameter(content, :Test, :func, 1, "opts", "options")

      assert new_content =~ "func(options \\\\ [])"
      assert new_content =~ "Keyword.get(options, :key)"
    end
  end
end
