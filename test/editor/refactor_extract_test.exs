defmodule Ragex.Editor.RefactorExtractTest do
  use ExUnit.Case, async: true

  alias Ragex.Editor.Refactor
  alias Ragex.Editor.Refactor.Elixir, as: ElixirRefactor

  describe "extract_function/6" do
    test "extracts simple code block" do
      content = """
      defmodule Test do
        def process(x) do
          y = x * 2
          z = y + 10
          z * 3
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.extract_function(
                 content,
                 :Test,
                 :process,
                 1,
                 :calculate,
                 {3, 4}
               )

      assert new_content =~ "defp calculate("
      assert new_content =~ "calculate("
    end

    test "infers free variables as parameters" do
      content = """
      defmodule Test do
        def process(x, y) do
          a = x + 1
          b = a * y
          c = b + 5
          c
        end
      end
      """

      # Extract lines that use both x and y
      assert {:ok, new_content} =
               ElixirRefactor.extract_function(
                 content,
                 :Test,
                 :process,
                 2,
                 :compute,
                 {4, 5}
               )

      # Should detect free variables (a, y) and pass them
      assert new_content =~ "defp compute("
      assert new_content =~ "compute("
    end

    @tag skip: true, reason: :phase_10a
    test "handles nested function calls" do
      content = """
      defmodule Test do
        def process(data) do
          cleaned = String.trim(data)
          upper = String.upcase(cleaned)
          result = String.reverse(upper)
          result
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.extract_function(
                 content,
                 :Test,
                 :process,
                 1,
                 :transform_string,
                 {4, 5}
               )

      assert new_content =~ "defp transform_string("
      assert new_content =~ "result = transform_string("
    end

    test "extracts with pattern matching" do
      content = """
      defmodule Test do
        def process({:ok, value}) do
          doubled = value * 2
          tripled = doubled * 1.5
          {:ok, tripled}
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.extract_function(
                 content,
                 :Test,
                 :process,
                 1,
                 :multiply,
                 {3, 4}
               )

      assert new_content =~ "defp multiply("
    end

    test "placement: :before inserts before source function" do
      content = """
      defmodule Test do
        def process(x) do
          y = x * 2
          z = y + 10
          z
        end

        def another_func, do: :ok
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.extract_function(
                 content,
                 :Test,
                 :process,
                 1,
                 :calculate,
                 {3, 4},
                 placement: :before
               )

      # Find positions
      calc_pos = :binary.match(new_content, "defp calculate(") |> elem(0)
      process_pos = :binary.match(new_content, "def process(") |> elem(0)

      assert calc_pos < process_pos
    end

    test "placement: :after inserts after source function" do
      content = """
      defmodule Test do
        def process(x) do
          y = x * 2
          z = y + 10
          z
        end

        def another_func, do: :ok
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.extract_function(
                 content,
                 :Test,
                 :process,
                 1,
                 :calculate,
                 {3, 4},
                 placement: :after
               )

      # Find positions - calculate should be after process end but before another_func
      process_end = :binary.match(new_content, "end\n\n  defp calculate") |> elem(0)
      another_pos = :binary.match(new_content, "def another_func") |> elem(0)

      assert process_end < another_pos
    end

    @tag skip: true, reason: :phase_10a
    test "extracts code with pipe operator" do
      content = """
      defmodule Test do
        def process(data) do
          result =
            data
            |> String.trim()
            |> String.upcase()
          result
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.extract_function(
                 content,
                 :Test,
                 :process,
                 1,
                 :transform,
                 {4, 6}
               )

      assert new_content =~ "defp transform("
      assert new_content =~ "result = transform("
    end

    test "fails with invalid line range" do
      content = """
      defmodule Test do
        def process(x) do
          x * 2
        end
      end
      """

      assert {:error, _reason} =
               ElixirRefactor.extract_function(
                 content,
                 :Test,
                 :process,
                 1,
                 :bad_extract,
                 {100, 200}
               )
    end

    test "fails with parse errors" do
      invalid_content = "defmodule Test do\n  def func("

      assert {:error, message} =
               ElixirRefactor.extract_function(
                 invalid_content,
                 :Test,
                 :func,
                 0,
                 :extracted,
                 {1, 2}
               )

      assert message =~ "Parse error"
    end

    @tag skip: true, reason: :phase_10a
    test "extracts code with multiple free variables" do
      content = """
      defmodule Test do
        def complex(a, b, c) do
          x = a + b
          y = b + c
          z = x * y
          result = z + a
          result
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.extract_function(
                 content,
                 :Test,
                 :complex,
                 3,
                 :calculate_result,
                 {5, 6}
               )

      # Should detect x, y, a as free variables
      assert new_content =~ "defp calculate_result("
      assert new_content =~ "result = calculate_result("
    end

    @tag skip: true, reason: :phase_10a
    test "extracts code with guards" do
      content = """
      defmodule Test do
        def process(x) when x > 0 do
          doubled = x * 2
          tripled = doubled * 1.5
          tripled
        end
      end
      """

      assert {:ok, new_content} =
               ElixirRefactor.extract_function(
                 content,
                 :Test,
                 :process,
                 1,
                 :multiply,
                 {3, 4}
               )

      assert new_content =~ "defp multiply("
    end
  end

  describe "Refactor.extract_function/6 integration" do
    setup do
      test_dir = Path.join(System.tmp_dir!(), "ragex_extract_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(test_dir)

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      %{test_dir: test_dir}
    end

    @tag skip: true, reason: :phase_10a
    test "creates backup and extracts function", %{test_dir: dir} do
      file_path = Path.join(dir, "test.ex")

      content = """
      defmodule MyModule do
        def calculate(x, y) do
          sum = x + y
          product = sum * 2
          {:ok, product}
        end
      end
      """

      File.write!(file_path, content)

      assert {:ok, result} =
               Refactor.extract_function(
                 :MyModule,
                 :calculate,
                 2,
                 :compute_product,
                 {4, 5},
                 validate: true,
                 format: false
               )

      assert result.status == :success
      assert [^file_path] = result.files_modified

      new_content = File.read!(file_path)
      assert new_content =~ "defp compute_product("
      assert new_content =~ "product = compute_product("
    end

    test "validation catches invalid extraction", %{test_dir: dir} do
      file_path = Path.join(dir, "test.ex")

      content = """
      defmodule MyModule do
        def func(x) do
          x * 2
        end
      end
      """

      File.write!(file_path, content)

      # Try to extract invalid line range
      result =
        Refactor.extract_function(
          :MyModule,
          :func,
          1,
          :extracted,
          {100, 200},
          validate: true
        )

      assert {:error, _} = result
    end
  end
end
