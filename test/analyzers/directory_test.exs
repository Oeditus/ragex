defmodule Ragex.Analyzers.DirectoryTest do
  use ExUnit.Case, async: false

  alias Ragex.Analyzers.Directory

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "ragex_dir_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "analyze_files/2 error recovery" do
    test "recovers from file with invalid byte / non-utf8 string literals", %{tmp_dir: tmp_dir} do
      good_file = Path.join(tmp_dir, "good.ex")
      bad_byte_file = Path.join(tmp_dir, "bad_byte.ex")

      File.write!(good_file, """
      defmodule GoodModule do
        def hello, do: :world
      end
      """)

      # Contains \xff\xfe invalid UTF-8 sequence in string literal
      File.write!(bad_byte_file, ~S"""
      defmodule BadByteModule do
        def faulty do
          "\xff\xfe invalid byte string"
        end
      end
      """)

      assert {:ok, summary} =
               Directory.analyze_files([good_file, bad_byte_file],
                 notify: false,
                 incremental: false,
                 generate_embeddings: false
               )

      assert summary.total == 2
      assert summary.analyzed == 2
      # Bad byte is now safely sanitized during AST serialization, so both succeed!
      assert summary.success == 2
      assert summary.errors == 0
    end

    test "recovers and continues when a file fails analysis completely", %{tmp_dir: tmp_dir} do
      good_file = Path.join(tmp_dir, "good.ex")
      broken_file = Path.join(tmp_dir, "broken.ex")

      File.write!(good_file, """
      defmodule GoodModule do
        def hello, do: :world
      end
      """)

      # Syntactically broken Elixir code that fails parsing
      File.write!(broken_file, """
      defmodule BrokenModule do
        def syntax_error(
      """)

      assert {:ok, summary} =
               Directory.analyze_files([good_file, broken_file],
                 notify: false,
                 incremental: false,
                 generate_embeddings: false
               )

      assert summary.total == 2
      assert summary.analyzed == 2
      assert summary.success == 1
      assert summary.errors == 1
      assert length(summary.error_details) == 1

      [error] = summary.error_details
      assert error.file == broken_file
      assert error.reason != nil
    end

    test "recovers and continues when a task times out", %{tmp_dir: tmp_dir} do
      slow_file = Path.join(tmp_dir, "slow.ex")

      content =
        "defmodule SlowModule do\n" <>
          Enum.map_join(1..1000, "\n", fn i -> "  def func_#{i}, do: #{i}" end) <>
          "\nend\n"

      File.write!(slow_file, content)

      assert {:ok, summary} =
               Directory.analyze_files([slow_file],
                 notify: false,
                 incremental: false,
                 generate_embeddings: false,
                 timeout: 1
               )

      assert summary.total == 1
      assert summary.errors == 1
      assert summary.success == 0
      [error] = summary.error_details
      assert error.file == slow_file
      assert match?({:task_exit, :timeout}, error.reason)
    end
  end
end
