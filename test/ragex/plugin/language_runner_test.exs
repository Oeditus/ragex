defmodule Ragex.Plugin.LanguageRunnerTest do
  use ExUnit.Case, async: true

  alias Ragex.Plugin.LanguageRunner

  # The runner reads the registry to discover plugins, but with no plugin
  # implementing `post_process/2` it is an identity function. These tests
  # therefore never mutate registry state -- doing so from a test made results
  # order-dependent for any concurrently-running test that read `list_tools/0`.

  defp doc(source) do
    {:ok, ast} = Metastatic.quote(source, :elixir)
    Metastatic.Document.new(ast, :elixir, %{}, source)
  end

  describe "plugins_for/1" do
    test "returns the Elixir plugin for :elixir" do
      assert Ragex.Plugins.Languages.Elixir in LanguageRunner.plugins_for(:elixir)
    end

    test "returns nothing for a language no plugin serves" do
      assert LanguageRunner.plugins_for(:cobol) == []
    end
  end

  describe "post_process/3" do
    test "is an identity function when no plugin implements the hook" do
      # The Elixir plugin deliberately implements no `post_process/2`: its
      # repairs moved upstream into Metastatic.
      original = doc("defmodule M do\n  def f, do: 1\nend")

      assert LanguageRunner.post_process(original, :elixir) == original
    end

    test "is an identity function for a language with no plugins" do
      original = doc("defmodule M do\n  def f, do: 1\nend")

      assert LanguageRunner.post_process(original, :cobol) == original
    end

    test "tolerates a non-document argument" do
      assert LanguageRunner.post_process(:not_a_doc, :elixir) == :not_a_doc
    end
  end
end
