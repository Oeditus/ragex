defmodule Ragex.LanguagesTest do
  @moduledoc """
  Tests for the derived Ragex language registry.

  `Ragex.Languages` derives from `Metastatic.Languages` and merges a Ragex-local
  overlay (validators, native analyzers, SCIP indexers). These tests lock in
  that derivation and the concerns that used to be hardcoded in four separate
  modules.
  """

  use ExUnit.Case, async: true

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
      refute Languages.has_adapter?(:go)
      refute Languages.has_adapter?(:rust)
      assert {:error, {:unsupported_language, :go}} = Languages.get_adapter(:go)
    end

    test "ruby carries both an adapter and a SCIP indexer" do
      assert Languages.has_adapter?(:ruby)
      assert %{indexer: "scip-ruby"} = Languages.scip_indexer(:ruby)
    end
  end

  describe "detect_language/1" do
    test "detects metastatic extensions" do
      assert Languages.detect_language("a.ex") == :elixir
      assert Languages.detect_language("a.ts") == :typescript
      assert Languages.detect_language("a.md") == :markdown
    end

    test "SCIP-only extensions are not detected (preserves contract)" do
      assert Languages.detect_language("a.go") == :unknown
      assert Languages.detect_language("a.c") == :unknown
      assert Languages.detect_language("a.rs") == :unknown
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
      refute ".go" in exts
      refute ".rs" in exts
    end
  end
end
