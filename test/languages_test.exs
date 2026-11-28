defmodule Ragex.LanguagesTest do
  @moduledoc """
  Tests for the derived Ragex language registry.

  `Ragex.Languages` derives from `Metastatic.Languages` and merges a Ragex-local
  overlay (validators, native analyzers, SCIP indexers). These tests lock in
  that derivation and the concerns that used to be hardcoded in four separate
  modules.
  """

  use ExUnit.Case, async: false

  alias Ragex.{Language, Languages}

  describe "derivation from Metastatic" do
    test "every Metastatic language is present" do
      for lang <- Metastatic.Languages.supported_languages() do
        assert Languages.supported?(lang),
               "Ragex.Languages is missing Metastatic language #{inspect(lang)}"
      end
    end

    test "adapters match Metastatic's" do
      for lang <- Metastatic.Languages.supported_languages() do
        assert Languages.get_adapter(lang) == Metastatic.Languages.get_adapter(lang)
      end
    end

    test "descriptors are %Ragex.Language{} structs" do
      assert Enum.all?(Languages.all(), &match?(%Language{}, &1))
    end

    test "available?/1 delegates to Metastatic.Adapter.available?/1" do
      assert Languages.available?(:elixir)
      assert Languages.available?(:erlang)
      assert Languages.available?(:markdown)
      refute Languages.available?(:c_cpp)
      refute Languages.available?(:unknown)

      for lang <- Metastatic.Languages.supported_languages() do
        {:ok, adapter} = Languages.get_adapter(lang)
        assert Languages.available?(lang) == Metastatic.Adapter.available?(adapter)
        assert Ragex.LanguageSupport.available?(lang) == Languages.available?(lang)
      end
    end
  end

  describe "validators overlay" do
    test "known languages map to their validators" do
      assert Languages.validator(:elixir) == Ragex.Editor.Validators.Elixir
      assert Languages.validator(:python) == Ragex.Editor.Validators.Python
      assert Languages.validator(:ruby) == Ragex.Editor.Validators.Ruby
      assert Languages.validator(:agda) == Ragex.Editor.Validators.Agda
    end

    test "typescript shares the JavaScript validator" do
      assert Languages.validator(:typescript) == Ragex.Editor.Validators.Javascript
    end

    test "languages without a validator return nil" do
      assert Languages.validator(:haskell) == nil
      assert Languages.validator(:go) == nil
    end

    test "validators/0 only includes languages that have one" do
      validators = Languages.validators()
      assert validators[:elixir] == Ragex.Editor.Validators.Elixir
      refute Map.has_key?(validators, :haskell)
      refute Map.has_key?(validators, :go)
    end
  end

  describe "native analyzers overlay" do
    test "known languages map to their analyzers" do
      assert Languages.native_analyzer(:elixir) == Ragex.Analyzers.Elixir
      assert Languages.native_analyzer(:python) == Ragex.Analyzers.Python
    end

    test "typescript shares the JavaScript analyzer" do
      assert Languages.native_analyzer(:typescript) == Ragex.Analyzers.JavaScript
    end

    test "native_analyzers/0 only includes languages that have one" do
      analyzers = Languages.native_analyzers()
      assert analyzers[:elixir] == Ragex.Analyzers.Elixir
      refute Map.has_key?(analyzers, :markdown)
      refute Map.has_key?(analyzers, :go)
    end
  end

  describe "SCIP languages" do
    test "the historical ten-language set is preserved" do
      names =
        Languages.scip_languages()
        |> Enum.map(& &1.language)
        |> Enum.sort()

      assert names == [
               :c_cpp,
               :csharp,
               :dart,
               :go,
               :java,
               :kotlin,
               :php,
               :ruby,
               :rust,
               :scala
             ]
    end

    test "SCIP-only languages have no adapter" do
      # `:go` graduated from SCIP-only to a first-class language when
      # `Metastatic.Adapters.Go` landed (Metastatic 0.43). `:c_cpp` is still
      # SCIP-only, so it carries the contract.
      refute Languages.has_adapter?(:c_cpp)
      assert {:error, {:unsupported_language, :c_cpp}} = Languages.get_adapter(:c_cpp)
    end

    test "go carries both an adapter and a SCIP indexer" do
      assert Languages.has_adapter?(:go)
      assert {:ok, Metastatic.Adapters.Go} = Languages.get_adapter(:go)
      assert %{indexer: "scip-go"} = Languages.scip_indexer(:go)
    end

    test "ruby carries both an adapter and a SCIP indexer" do
      assert Languages.has_adapter?(:ruby)
      assert %{indexer: "scip-ruby"} = Languages.scip_indexer(:ruby)
    end

    test "rust carries both an adapter and a SCIP indexer" do
      # Rust graduated from SCIP-only to a first-class language when
      # `Metastatic.Adapters.Rust` landed; the SCIP entry remains for projects
      # that want precise cross-file symbol indexing.
      assert Languages.has_adapter?(:rust)
      assert %{indexer: "rust-analyzer"} = Languages.scip_indexer(:rust)
    end
  end

  describe "detect_language/1" do
    test "detects metastatic extensions" do
      assert Languages.detect_language("a.ex") == :elixir
      assert Languages.detect_language("a.ts") == :typescript
      assert Languages.detect_language("a.md") == :markdown
    end

    test "detects LFE" do
      # `.lfe` arrived with `Metastatic.Adapters.Lfe` (Metastatic 0.40).
      assert Languages.detect_language("src/demo.lfe") == :lfe
      assert Languages.detect_language("demo.lfe") == :lfe
    end

    test "detects both Haskell extensions" do
      # `.hs` was always supported; `.lhs` (literate Haskell) is part of the
      # same adapter and must not be mistaken for an unknown extension.
      assert Languages.detect_language("Main.hs") == :haskell
      assert Languages.detect_language("Literate.lhs") == :haskell
    end

    test "SCIP-only extensions are not detected (preserves contract)" do
      # `.go` moved out of this contract when `Metastatic.Adapters.Go` landed;
      # `.c` remains SCIP-only.
      assert Languages.detect_language("a.c") == :unknown
    end

    test "go is detected now that it has an adapter" do
      assert Languages.detect_language("a.go") == :go
    end

    test "rust is detected now that it has an adapter" do
      # `.rs` used to be SCIP-only; `Metastatic.Adapters.Rust` made it
      # detectable, so it moved out of this contract's scope.
      assert Languages.detect_language("a.rs") == :rust
    end
  end

  describe "documentation languages" do
    test "markdown is a documentation language" do
      assert Languages.documentation_language?(:markdown)
      assert Languages.documentation_file?("README.md")
      assert Languages.documentation_extension?(".md")
    end

    test "code languages are not documentation" do
      refute Languages.documentation_language?(:elixir)
      refute Languages.documentation_file?("lib/x.ex")
      refute Languages.documentation_extension?(".ex")
    end
  end

  describe "supported_extensions/0" do
    test "only includes metastatic extensions (SCIP handled separately)" do
      exts = Languages.supported_extensions()
      assert ".ex" in exts
      assert ".py" in exts
      # `.rs` and `.go` are Metastatic extensions now; `.c` remains SCIP-only.
      assert ".rs" in exts
      assert ".go" in exts
      refute ".c" in exts
    end

    test "includes the Haskell and LFE extensions" do
      exts = Languages.supported_extensions()
      assert ".hs" in exts
      assert ".lhs" in exts
      assert ".lfe" in exts
    end
  end

  describe "LFE and Haskell descriptors" do
    test "LFE is advertised as experimental, like Metastatic does" do
      # LFE's reader/compiler are not part of OTP, so Metastatic flags the
      # language experimental; Ragex must not silently upgrade that claim.
      assert %Language{language: :lfe, experimental?: true} = Languages.get(:lfe)
      assert Languages.supported?(:lfe)
      assert Languages.has_adapter?(:lfe)
      assert Languages.get_adapter(:lfe) == {:ok, Metastatic.Adapters.Lfe}
    end

    test "Haskell is advertised as experimental and carries both extensions" do
      assert %Language{language: :haskell, experimental?: true, extensions: exts} =
               Languages.get(:haskell)

      assert ".hs" in exts
      assert ".lhs" in exts
      assert Languages.get_adapter(:haskell) == {:ok, Metastatic.Adapters.Haskell}
    end

    test "neither language claims a Ragex validator or native analyzer" do
      # Ragex has no Haskell/LFE validator and no native fallback analyzer for
      # them, so the overlay must resolve to `nil` rather than a stale module.
      assert Languages.validator(:lfe) == nil
      assert Languages.validator(:haskell) == nil
      assert Languages.native_analyzer(:lfe) == nil
      assert Languages.native_analyzer(:haskell) == nil
    end

    test "neither language is a documentation language" do
      refute Languages.documentation_language?(:lfe)
      refute Languages.documentation_language?(:haskell)
      refute Languages.documentation_file?("src/demo.lfe")
      refute Languages.documentation_file?("Main.hs")
    end
  end

  describe "runtime Metastatic language plugins" do
    test "runtime-registered Metastatic adapters are immediately visible" do
      lang = :ragex_test_plugin_lang
      ext = ".ragex_test_ext"

      on_exit(fn ->
        Metastatic.Languages.unregister(lang)
      end)

      refute Languages.supported?(lang)
      assert Languages.detect_language("sample#{ext}") == :unknown

      assert :ok =
               Metastatic.Languages.register(lang, Metastatic.Adapters.Elixir, extensions: [ext])

      assert Languages.supported?(lang)
      assert Languages.has_adapter?(lang)
      assert Languages.metastatic_language?(lang)
      assert Languages.get_adapter(lang) == {:ok, Metastatic.Adapters.Elixir}
      assert Languages.detect_language("sample#{ext}") == lang
      assert ext in Languages.supported_extensions()
      assert ext in Languages.metastatic_extensions()
      assert %Language{language: ^lang, adapter: Metastatic.Adapters.Elixir} = Languages.get(lang)
      assert Enum.any?(Languages.all(), &(&1.language == lang))
    end
  end
end
