defmodule Ragex.Analysis.MetaCredoBridgeTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.MetaCredoBridge

  describe "parse_source_file/3 encoding handling" do
    test "parses valid UTF-8 source" do
      source = """
      defmodule Greeter do
        def hello, do: "héllo"
      end
      """

      assert {:ok, source_file} = MetaCredoBridge.parse_source_file(source, "greeter.ex", :elixir)
      assert source_file.filename == "greeter.ex"
      assert source_file.language == :elixir
    end

    test "sanitises invalid UTF-8 instead of skipping the file" do
      # 0xF1 is Latin-1 "ñ", which is invalid on its own in UTF-8. The other
      # analysis paths (MetastaticBridge, Analyzers.Directory) sanitise such
      # files; skipping them here meant the same file was analysed by one code
      # path and silently ignored by another.
      source =
        IO.iodata_to_binary([
          "defmodule Latin do\n  # Tallak ",
          <<241>>,
          " Tveide\n  def t, do: :ok\nend\n"
        ])

      refute String.valid?(source)

      assert {:ok, source_file} = MetaCredoBridge.parse_source_file(source, "latin.ex", :elixir)
      assert source_file.filename == "latin.ex"
      # The replacement character is substituted for the invalid byte.
      assert String.valid?(source_file.source)
      assert source_file.source =~ "Tallak"
    end
  end

  describe "parse_file/1 encoding handling" do
    test "sanitises a file with invalid UTF-8 rather than erroring" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "latin_#{:rand.uniform(999_999)}.ex")

      File.write!(
        path,
        IO.iodata_to_binary([
          "defmodule LatinFile do\n  # Tallak ",
          <<241>>,
          " Tveide\n  def t, do: :ok\nend\n"
        ])
      )

      on_exit(fn -> File.rm(path) end)

      assert {:ok, source_file} = MetaCredoBridge.parse_file(path)
      assert source_file.filename == path
      assert String.valid?(source_file.source)
    end
  end
end
