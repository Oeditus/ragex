defmodule Ragex.Analyzers.HaskellLfeSupportTest do
  @moduledoc """
  End-to-end coverage for the two language capabilities Ragex inherits from
  Metastatic 0.40: the improved Haskell adapter and the new LFE adapter.

  These tests pin the *Ragex* side of the integration -- detection, adapter
  resolution, MetaAST extraction, deeper indexing and the formatter fallback --
  rather than re-testing Metastatic's own adapter conformance suites.

  ## Why the parsing tests are tolerant

  Both languages depend on toolchains that are not part of OTP:

    * Haskell needs the `haskell-src-exts` parser binary (or `stack` to build
      it) behind a subprocess bridge;
    * LFE needs `lfe_scan`/`lfe_io`/`lfe_comp` on the code path.

  A machine without them must still get a clean `{:error, reason}` -- never a
  raise, never a crash in the MCP handlers. So every test that actually parses
  asserts the *contract* (a well-formed result tuple) and only asserts the
  parsed shape when the toolchain reports itself available.
  """

  use ExUnit.Case, async: true

  alias Metastatic.Adapters.{Haskell, Lfe}
  alias Ragex.Analyzers.DeeperIndexing
  alias Ragex.Analyzers.Metastatic, as: MetastaticAnalyzer
  alias Ragex.Editor.Formatter
  alias Ragex.LanguageSupport

  @haskell_source """
  module Demo where

  data Shape = Circle { radius :: Double } | Square { side :: Double }

  double :: Int -> Int
  double x = x * 2

  area :: Shape -> Double
  area (Circle { radius = r }) = 3.14 * r * r
  area (Square { side = s }) = s * s
  """

  @lfe_source """
  (defmodule demo
    (export (add 2)))

  ;; Adds two numbers
  (defun add (a b)
    (+ a b))
  """

  # The Haskell adapter reports availability by returning an error from
  # `parse/1` rather than exposing an `available?/0` predicate, so probing is
  # the only way to know whether the parser binary is reachable.
  defp haskell_available? do
    match?({:ok, _}, Haskell.parse("1"))
  end

  defp lfe_available?, do: Lfe.available?()

  describe "Haskell" do
    test "is detected from both .hs and .lhs" do
      assert LanguageSupport.detect_language("Main.hs") == :haskell
      assert LanguageSupport.detect_language("Literate.lhs") == :haskell
    end

    test "resolves to the Metastatic Haskell adapter" do
      assert {:ok, Metastatic.Adapters.Haskell} = LanguageSupport.get_adapter(:haskell)
      assert LanguageSupport.has_adapter?(:haskell)
    end

    test "parses real-world constructs into MetaAST without unsupported nodes" do
      # `data` declarations with record syntax, `::` signatures and pattern
      # matches on records are exactly the constructs Metastatic 0.40 added.
      # Before that release they surfaced as `unsupported` nodes and the file
      # fell back to the native analyzer.
      case LanguageSupport.parse_document(@haskell_source, :haskell) do
        {:ok, %Metastatic.Document{language: :haskell, ast: ast}} ->
          assert {:container, meta, children} = ast
          assert meta[:container_type] == :module
          assert children != []

          rendered = inspect(ast, limit: :infinity)
          refute rendered =~ "unsupported"
          refute rendered =~ "unsupported_pat"

        {:error, reason} ->
          # Toolchain missing: the contract is still "error tuple, not raise".
          assert is_binary(reason) or is_atom(reason)
      end
    end

    test "the language-agnostic analyzer extracts Haskell entities" do
      if haskell_available?() do
        assert {:ok, analysis} = MetastaticAnalyzer.analyze(@haskell_source, "Demo.hs")

        names = Enum.map(analysis.functions, & &1.name)
        assert :double in names
        assert :area in names
      else
        # Without a parser the analyzer must degrade, not crash.
        assert {:ok, _analysis} = MetastaticAnalyzer.analyze(@haskell_source, "Demo.hs")
      end
    end

    test "malformed source yields an error tuple rather than an exception" do
      assert {:error, _reason} =
               LanguageSupport.parse_document("module where (", :haskell)
    end
  end

  describe "LFE" do
    test "is detected from .lfe" do
      assert LanguageSupport.detect_language("src/demo.lfe") == :lfe
      assert LanguageSupport.detect_language("demo.lfe") == :lfe
    end

    test "resolves to the Metastatic LFE adapter" do
      assert {:ok, Metastatic.Adapters.Lfe} = LanguageSupport.get_adapter(:lfe)
      assert LanguageSupport.has_adapter?(:lfe)
    end

    test "parses a module and function into MetaAST" do
      case LanguageSupport.parse_document(@lfe_source, :lfe) do
        {:ok, %Metastatic.Document{language: :lfe, ast: ast}} ->
          assert {:block, _meta, children} = ast

          assert Enum.any?(children, fn
                   {:container, meta, _} -> meta[:container_type] == :module
                   _ -> false
                 end)

          assert Enum.any?(children, fn
                   {:function_def, meta, _} -> meta[:name] == "add" and meta[:arity] == 2
                   _ -> false
                 end)

        {:error, reason} ->
          assert is_binary(reason) or is_atom(reason)
      end
    end

    test "the language-agnostic analyzer extracts LFE entities" do
      if lfe_available?() do
        assert {:ok, analysis} = MetastaticAnalyzer.analyze(@lfe_source, "demo.lfe")

        assert Enum.any?(analysis.functions, &(&1.name == :add and &1.arity == 2))
        assert Enum.any?(analysis.modules, &(&1.name == "demo"))
      else
        assert {:ok, _analysis} = MetastaticAnalyzer.analyze(@lfe_source, "demo.lfe")
      end
    end

    test "macro expansion is offered as a second view, not a replacement" do
      # `expand_macros: true` must leave the surface MetaAST untouched (it is
      # the round-trippable one) and attach the expanded Core Erlang module to
      # the metadata instead.
      if lfe_available?() and Lfe.expansion_available?() do
        assert {:ok, forms} = Lfe.parse(@lfe_source)

        assert {:ok, surface, metadata} =
                 Lfe.to_meta(forms, expand_macros: true)

        assert {:block, _, _} = surface
        assert :c_module = elem(metadata.core, 0)
      else
        assert {:ok, forms} = Lfe.parse(@lfe_source)
        assert {:ok, {:block, _, _}, _metadata} = Lfe.to_meta(forms)
      end
    end

    test "round-trips through from_meta/unparse" do
      if lfe_available?() do
        assert {:ok, forms} = Lfe.parse(@lfe_source)
        assert {:ok, meta, metadata} = Lfe.to_meta(forms)
        assert {:ok, restored} = Lfe.from_meta(meta, metadata)
        assert {:ok, source} = Lfe.unparse(restored)

        assert source =~ "(defmodule demo"
        assert source =~ "(defun add (a b)"
      else
        # The reader is the single availability gate; without it nothing else
        # in the adapter may be reached.
        assert {:error, reason} = Lfe.parse(@lfe_source)
        assert is_binary(reason)
      end
    end

    test "malformed source yields an error tuple rather than an exception" do
      assert {:error, reason} = LanguageSupport.parse_document("(defun add", :lfe)
      assert is_binary(reason) or is_atom(reason)
    end
  end

  describe "DeeperIndexing" do
    test "extracts Haskell string literals" do
      source = """
      module Demo where

      greeting :: String
      greeting = "Hello, Haskell!"
      """

      assert [{"Hello, Haskell!", _line}] =
               Enum.map(
                 DeeperIndexing.extract_strings(source, :haskell),
                 fn {line, text} -> {text, line} end
               )
    end

    test "extracts Haskell line and block comments" do
      source = """
      -- Top-level note
      module Demo where

      {- Block note
         spanning lines -}
      """

      comments = DeeperIndexing.extract_comments(source, :haskell)
      texts = Enum.map(comments, &elem(&1, 1))

      assert Enum.any?(texts, &String.contains?(&1, "Top-level note"))
      assert Enum.any?(texts, &String.contains?(&1, "Block note"))
    end

    test "extracts LFE string literals" do
      source = """
      (defun greet ()
        (io:format "Hello, LFE!"))
      """

      assert [{"Hello, LFE!", _line}] =
               Enum.map(
                 DeeperIndexing.extract_strings(source, :lfe),
                 fn {line, text} -> {text, line} end
               )
    end

    test "extracts LFE comments and strips the whole semicolon run" do
      source = """
      ;;; Module commentary
      (defun add (a b)
        ;; Adds two numbers
        (+ a b))
      """

      texts = Enum.map(DeeperIndexing.extract_comments(source, :lfe), &elem(&1, 1))

      assert "Module commentary" in texts
      assert "Adds two numbers" in texts
      refute Enum.any?(texts, &String.starts_with?(&1, ";"))
    end

    test "associates LFE strings and comments with functions via extract/3" do
      analysis = %{functions: [], modules: []}
      enrichment = DeeperIndexing.extract(@lfe_source, "demo.lfe", analysis)

      strings = enrichment.strings |> Map.values() |> List.flatten()
      comments = enrichment.comments |> Map.values() |> List.flatten()

      # No strings in the fixture, but the comment must be indexed.
      assert strings == []
      assert Enum.any?(comments, &String.contains?(&1, "Adds two numbers"))
    end

    test "unknown languages still yield empty enrichment" do
      analysis = %{functions: [], modules: []}
      enrichment = DeeperIndexing.extract("x = 1", "file.txt", analysis)

      assert enrichment.strings == %{}
      assert enrichment.comments == %{}
    end
  end

  describe "Formatter" do
    test "has no external formatter for Haskell or LFE" do
      # Neither language ships a formatter Ragex can shell out to, so the
      # formatter step must be a no-op rather than an error. This keeps
      # `edit_file`/refactoring usable on those files.
      refute Formatter.available?("Demo.hs")
      refute Formatter.available?("demo.lfe")
    end
  end
end
