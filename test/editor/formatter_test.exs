defmodule Ragex.Editor.FormatterTest do
  use ExUnit.Case, async: true

  alias Ragex.Editor.Formatter

  setup do
    temp_dir = System.tmp_dir!()
    test_dir = Path.join(temp_dir, "ragex_formatter_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "format/2" do
    test "formats Elixir files with mix format", %{test_dir: dir} do
      test_file = Path.join(dir, "test.ex")

      # Unformatted Elixir code
      unformatted = "defmodule    Test   do\n  def   hello   ,   do:    :world\nend\n"

      File.write!(test_file, unformatted)

      # Format the file
      assert :ok = Formatter.format(test_file)

      # Check that file was modified (mix format should clean it up)
      formatted = File.read!(test_file)
      assert formatted != unformatted
      assert formatted =~ "defmodule Test do"
    end

    test "returns ok for files without formatters", %{test_dir: dir} do
      test_file = Path.join(dir, "test.txt")
      File.write!(test_file, "some text")

      assert :ok = Formatter.format(test_file)
    end

    test "handles missing files gracefully", %{test_dir: dir} do
      test_file = Path.join(dir, "nonexistent.ex")

      # Should not crash, may return error or ok
      result = Formatter.format(test_file)

      case result do
        :ok -> assert true
        {:error, _} -> assert true
        _ -> flunk("Expected :ok or {:error, _}, got #{inspect(result)}")
      end
    end

    test "supports language override", %{test_dir: dir} do
      test_file = Path.join(dir, "script.ex")

      # Unformatted Elixir code
      unformatted = "defmodule    Test   do\n  def   hello   ,   do:    :world\nend\n"

      File.write!(test_file, unformatted)

      # Format with explicit language (even though extension would work)
      assert :ok = Formatter.format(test_file, language: :elixir)

      # Should be formatted
      formatted = File.read!(test_file)
      assert formatted != unformatted
      assert formatted =~ "defmodule Test do"
    end
  end

  describe "available?/2" do
    test "returns true for Elixir files" do
      assert Formatter.available?("lib/module.ex")
      assert Formatter.available?("test/test.exs")
    end

    test "returns false for unsupported file types" do
      refute Formatter.available?("file.txt")
      refute Formatter.available?("data.json")
    end

    test "checks Python formatters if available" do
      # Python formatter availability depends on system
      python_available = Formatter.available?("script.py")
      assert is_boolean(python_available)
    end

    test "checks JavaScript formatters if available" do
      # JS formatter availability depends on system
      js_available = Formatter.available?("script.js")
      assert is_boolean(js_available)
    end
  end

  describe "integration with Core.edit_file" do
    test "formats after edit when format: true", %{test_dir: dir} do
      alias Ragex.Editor.{Core, Types}

      test_file = Path.join(dir, "test.ex")

      # Create unformatted file
      File.write!(test_file, "defmodule Test do\nend\n")

      # Edit with format option (insert function with proper end)
      changes = [
        Types.replace(1, 2, "defmodule Test do\n  def   hello  ,  do:   :world\nend")
      ]

      assert {:ok, _result} = Core.edit_file(test_file, changes, format: true, validate: false)

      # Check that result is formatted
      content = File.read!(test_file)
      assert content =~ ~r/def hello, do: :world/
    end

    test "does not format when format: false", %{test_dir: dir} do
      alias Ragex.Editor.{Core, Types}

      test_file = Path.join(dir, "test.ex")

      File.write!(test_file, "defmodule Test do\nend\n")

      # Edit without format
      changes = [
        Types.replace(1, 2, "defmodule Test do\n  def   hello  ,  do:   :world\nend")
      ]

      assert {:ok, _result} = Core.edit_file(test_file, changes, format: false, validate: false)

      # Check that result is NOT formatted (spacing preserved)
      content = File.read!(test_file)
      assert content =~ ~r/def   hello  ,  do:   :world/
    end
  end
end
