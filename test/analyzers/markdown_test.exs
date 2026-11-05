defmodule Ragex.Analyzers.MarkdownTest do
  use ExUnit.Case, async: true

  alias Ragex.Analyzers.Metastatic, as: MetastaticAnalyzer

  @document """
  # Title

  Some *prose* with a [link](https://example.com).

  ## Section

  - item one
  - item two

  ```elixir
  def hello, do: :world
  ```
  """

  describe "analyze/2 on Markdown" do
    test "returns a single document entity for the file" do
      assert {:ok, analysis} = MetastaticAnalyzer.analyze(@document, "docs/README.md")

      assert [module] = analysis.modules
      assert module.name == "README"
      assert module.file == "docs/README.md"
      assert module.line == 1
      assert module.metadata == %{container_type: :document, language: :markdown}
    end

    test "reports no functions, calls or imports" do
      assert {:ok, analysis} = MetastaticAnalyzer.analyze(@document, "README.md")

      assert analysis.functions == []
      assert analysis.calls == []
      assert analysis.imports == []
    end

    test "sanitises the base name into a valid entity name" do
      assert {:ok, %{modules: [module]}} =
               MetastaticAnalyzer.analyze("# Title", "docs/getting-started.v2.md")

      assert module.name == "getting_started_v2"
    end

    test "handles the .markdown extension" do
      assert {:ok, %{modules: [module]}} =
               MetastaticAnalyzer.analyze("# Title", "GUIDE.markdown")

      assert module.name == "GUIDE"
    end

    test "handles an empty document" do
      assert {:ok, %{modules: [module], functions: []}} =
               MetastaticAnalyzer.analyze("", "EMPTY.md")

      assert module.name == "EMPTY"
    end
  end

  describe "supported_extensions/0" do
    test "advertises Markdown extensions" do
      extensions = MetastaticAnalyzer.supported_extensions()

      assert ".md" in extensions
      assert ".markdown" in extensions
    end
  end

  describe "code languages are unaffected" do
    test "Elixir source still yields real modules and functions" do
      source = """
      defmodule MyApp.Calculator do
        def add(a, b), do: a + b
      end
      """

      assert {:ok, analysis} = MetastaticAnalyzer.analyze(source, "lib/calculator.ex")

      assert [module] = analysis.modules
      assert module.name == MyApp.Calculator
      assert [function] = analysis.functions
      assert function.name == :add
      assert function.arity == 2
    end
  end
end
