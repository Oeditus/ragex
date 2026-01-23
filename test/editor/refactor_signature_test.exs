defmodule Ragex.Editor.RefactorSignatureTest do
  use ExUnit.Case, async: true

  alias Ragex.Editor.Refactor.Elixir, as: ElixirRefactor

  describe "modify_attributes/3" do
    test "adds new attribute" do
      content = """
      defmodule Test do
        @moduledoc "Test module"

        def func, do: :ok
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.modify_attributes(content, :Test, [{:add, :behaviour, "GenServer"}])

      assert new_content =~ "@behaviour GenServer"
      assert new_content =~ "@moduledoc"
    end

    test "removes existing attribute" do
      content = """
      defmodule Test do
        @moduledoc "Test module"
        @deprecated "Use new_func instead"

        def func, do: :ok
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.modify_attributes(content, :Test, [{:remove, :deprecated}])

      refute new_content =~ "@deprecated"
      assert new_content =~ "@moduledoc"
    end

    test "updates existing attribute" do
      content = """
      defmodule Test do
        @moduledoc "Old docs"

        def func, do: :ok
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.modify_attributes(content, :Test, [
                 {:update, :moduledoc, "New documentation"}
               ])

      assert new_content =~ "@moduledoc \"New documentation\""
      refute new_content =~ "Old docs"
    end

    test "handles multiple attribute changes" do
      content = """
      defmodule Test do
        @moduledoc "Test"
        @deprecated "Old"

        def func, do: :ok
      end
      """

      changes = [
        {:update, :moduledoc, "Updated"},
        {:remove, :deprecated},
        {:add, :behaviour, "GenServer"}
      ]

      assert {:ok, new_content} =
               ElixirRefactor.modify_attributes(content, :Test, changes)

      assert new_content =~ "@moduledoc \"Updated\""
      assert new_content =~ "@behaviour GenServer"
      refute new_content =~ "@deprecated"
    end

    test "fails when adding duplicate attribute" do
      content = """
      defmodule Test do
        @moduledoc "Test"
      end
      """

      assert {:error, message} =
               ElixirRefactor.modify_attributes(content, :Test, [{:add, :moduledoc, "Dup"}])

      assert message =~ "already exists"
    end

    test "fails when removing non-existent attribute" do
      content = """
      defmodule Test do
        @moduledoc "Test"
      end
      """

      assert {:error, message} =
               ElixirRefactor.modify_attributes(content, :Test, [{:remove, :nonexistent}])

      assert message =~ "not found"
    end

    test "adds custom attribute" do
      content = """
      defmodule Test do
        @moduledoc "Test"
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.modify_attributes(content, :Test, [{:add, :custom_attr, "value"}])

      assert new_content =~ "@custom_attr \"value\""
    end
  end

  describe "change_signature/5" do
    test "adds parameter at end" do
      content = """
      defmodule Test do
        def func(x) do
          x * 2
        end

        def caller, do: func(5)
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.change_signature(content, :Test, :func, 1, [{:add, "opts", 1, []}])

      # Definition should have new parameter
      assert new_content =~ "func(x, opts \\\\ [])"
      # Calls should pass default
      assert new_content =~ "func(5, [])"
    end

    test "removes parameter" do
      content = """
      defmodule Test do
        def func(x, y) do
          x * 2
        end

        def caller, do: func(5, 10)
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.change_signature(content, :Test, :func, 2, [{:remove, 1}])

      # Definition should have only x
      assert new_content =~ "func(x)"
      # Calls should pass only first arg
      assert new_content =~ "func(5)"
    end

    @tag :skip
    test "reorders parameters" do
      content = """
      defmodule Test do
        def func(x, y) do
          x - y
        end

        def caller, do: func(10, 5)
      end
      """

      # Swap parameters
      assert {:ok, new_content} =
               ElixirRefactor.change_signature(content, :Test, :func, 2, [{:reorder, 0, 1}])

      # Definition should be swapped
      assert new_content =~ "func(y, x)"
      # Calls should be reordered
      assert new_content =~ "func(5, 10)"
    end

    test "renames parameter" do
      content = """
      defmodule Test do
        def func(old_name) do
          old_name * 2
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.change_signature(content, :Test, :func, 1, [
                 {:rename, 0, "new_name"}
               ])

      assert new_content =~ "func(new_name)"
      assert new_content =~ "new_name * 2"
    end

    test "combines multiple changes" do
      content = """
      defmodule Test do
        def process(x, y) do
          x + y
        end

        def caller, do: process(1, 2)
      end
      """

      changes = [
        {:rename, 0, "first"},
        {:rename, 1, "second"},
        {:add, "opts", 2, []}
      ]

      assert {:ok, new_content} =
               ElixirRefactor.change_signature(content, :Test, :process, 2, changes)

      assert new_content =~ "process(first, second, opts \\\\ [])"
      assert new_content =~ "first + second"
      assert new_content =~ "process(1, 2, [])"
    end

    test "updates qualified calls" do
      content = """
      defmodule Test do
        def func(x), do: x

        def caller, do: Test.func(5)
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.change_signature(content, :Test, :func, 1, [{:add, "y", 1, 0}])

      assert new_content =~ "func(x, y \\\\ 0)"
      assert new_content =~ "Test.func(5, 0)"
    end

    test "handles multi-clause functions" do
      content = """
      defmodule Test do
        def func(0), do: :zero
        def func(n), do: n * 2
      end
      """

      # Add parameter to all clauses
      assert {:ok, new_content} =
               ElixirRefactor.change_signature(content, :Test, :func, 1, [{:add, "opts", 1, []}])

      assert new_content =~ "func(0, opts \\\\ [])"
      assert new_content =~ "func(n, opts \\\\ [])"
    end

    test "fails when removing parameter still in use" do
      content = """
      defmodule Test do
        def func(x, y) do
          x + y
        end
      end
      """

      # Try to remove x which is used in body
      assert {:error, _message} =
               ElixirRefactor.change_signature(content, :Test, :func, 2, [{:remove, 0}])
    end
  end
end
