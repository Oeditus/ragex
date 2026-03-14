defmodule Ragex.LanguageSupportTest do
  use ExUnit.Case, async: true

  alias Ragex.LanguageSupport

  describe "detect_language/1" do
    test "detects Elixir" do
      assert :elixir = LanguageSupport.detect_language("lib/my_module.ex")
      assert :elixir = LanguageSupport.detect_language("test/my_test.exs")
    end

    test "detects Erlang" do
      assert :erlang = LanguageSupport.detect_language("src/my_module.erl")
      assert :erlang = LanguageSupport.detect_language("include/header.hrl")
    end

    test "detects Python" do
      assert :python = LanguageSupport.detect_language("script.py")
    end

    test "detects Ruby" do
      assert :ruby = LanguageSupport.detect_language("app/models/user.rb")
    end

    test "detects Haskell" do
      assert :haskell = LanguageSupport.detect_language("Main.hs")
    end

    test "detects JavaScript family" do
      assert :javascript = LanguageSupport.detect_language("index.js")
      assert :javascript = LanguageSupport.detect_language("App.jsx")
      assert :javascript = LanguageSupport.detect_language("index.ts")
      assert :javascript = LanguageSupport.detect_language("App.tsx")
      assert :javascript = LanguageSupport.detect_language("utils.mjs")
      assert :javascript = LanguageSupport.detect_language("utils.cjs")
    end

    test "returns :unknown for unsupported extensions" do
      assert :unknown = LanguageSupport.detect_language("file.txt")
      assert :unknown = LanguageSupport.detect_language("Makefile")
      assert :unknown = LanguageSupport.detect_language("file.c")
    end
  end

  describe "get_adapter/1" do
    test "returns adapter for supported Metastatic languages" do
      assert {:ok, Metastatic.Adapters.Elixir} = LanguageSupport.get_adapter(:elixir)
      assert {:ok, Metastatic.Adapters.Erlang} = LanguageSupport.get_adapter(:erlang)
      assert {:ok, Metastatic.Adapters.Python} = LanguageSupport.get_adapter(:python)
      assert {:ok, Metastatic.Adapters.Ruby} = LanguageSupport.get_adapter(:ruby)
      assert {:ok, Metastatic.Adapters.Haskell} = LanguageSupport.get_adapter(:haskell)
    end

    test "returns error for JavaScript (no adapter yet)" do
      assert {:error, {:unsupported_language, :javascript}} =
               LanguageSupport.get_adapter(:javascript)
    end

    test "returns error for :unknown" do
      assert {:error, {:unsupported_language, :unknown}} = LanguageSupport.get_adapter(:unknown)
    end
  end

  describe "parse_document/3" do
    test "parses valid Elixir source" do
      source = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      assert {:ok, %Metastatic.Document{}} = LanguageSupport.parse_document(source, :elixir)
    end

    test "returns error for unsupported language" do
      assert {:error, {:unsupported_language, :javascript}} =
               LanguageSupport.parse_document("const x = 1;", :javascript)
    end
  end

  describe "parse_file/2" do
    test "parses an existing Elixir file" do
      # Use this test file itself as input
      assert {:ok, %Metastatic.Document{}} =
               LanguageSupport.parse_file("test/language_support_test.exs")
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = LanguageSupport.parse_file("nonexistent.ex")
    end
  end

  describe "find_source_files/2" do
    setup do
      tmp = System.tmp_dir!()
      dir = Path.join(tmp, "ragex_lang_test_#{:rand.uniform(100_000)}")
      sub = Path.join(dir, "sub")
      File.mkdir_p!(sub)

      # Create test files
      File.write!(Path.join(dir, "a.ex"), "")
      File.write!(Path.join(dir, "b.py"), "")
      File.write!(Path.join(dir, "c.txt"), "")
      File.write!(Path.join(sub, "d.erl"), "")
      File.write!(Path.join(sub, "e.js"), "")

      on_exit(fn -> File.rm_rf!(dir) end)

      %{dir: dir, sub: sub}
    end

    test "finds all source files recursively", %{dir: dir} do
      {:ok, files} = LanguageSupport.find_source_files(dir)
      basenames = Enum.map(files, &Path.basename/1) |> Enum.sort()
      assert basenames == ["a.ex", "b.py", "d.erl", "e.js"]
    end

    test "non-recursive skips subdirectories", %{dir: dir} do
      {:ok, files} = LanguageSupport.find_source_files(dir, recursive: false)
      basenames = Enum.map(files, &Path.basename/1) |> Enum.sort()
      assert basenames == ["a.ex", "b.py"]
    end

    test "metastatic_only excludes JavaScript", %{dir: dir} do
      {:ok, files} = LanguageSupport.find_source_files(dir, metastatic_only: true)
      basenames = Enum.map(files, &Path.basename/1) |> Enum.sort()
      assert basenames == ["a.ex", "b.py", "d.erl"]
    end

    test "handles single file path", %{dir: dir} do
      file = Path.join(dir, "a.ex")
      assert {:ok, [^file]} = LanguageSupport.find_source_files(file)
    end

    test "returns error for nonexistent path" do
      assert {:error, {:not_found, _}} = LanguageSupport.find_source_files("/no/such/path")
    end
  end

  describe "supported_extensions/0" do
    test "returns a list of all extensions" do
      exts = LanguageSupport.supported_extensions()
      assert ".ex" in exts
      assert ".js" in exts
      assert ".py" in exts
    end
  end

  describe "metastatic_extensions/0" do
    test "excludes JavaScript extensions" do
      exts = LanguageSupport.metastatic_extensions()
      assert ".ex" in exts
      assert ".py" in exts
      refute ".js" in exts
      refute ".ts" in exts
    end
  end

  describe "has_adapter?/1" do
    test "true for languages with adapters" do
      assert LanguageSupport.has_adapter?(:elixir)
      assert LanguageSupport.has_adapter?(:python)
    end

    test "false for JavaScript and unknown" do
      refute LanguageSupport.has_adapter?(:javascript)
      refute LanguageSupport.has_adapter?(:unknown)
    end
  end
end
