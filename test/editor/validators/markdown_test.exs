defmodule Ragex.Editor.Validators.MarkdownTest do
  use ExUnit.Case, async: true

  alias Ragex.Editor.Validator
  alias Ragex.Editor.Validators.Markdown

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

  describe "can_validate?/1" do
    test "accepts the canonical Markdown extensions" do
      assert Markdown.can_validate?("README.md")
      assert Markdown.can_validate?("docs/guide.markdown")
    end

    test "rejects MDX, which embeds JSX rather than Markdown" do
      refute Markdown.can_validate?("page.mdx")
    end

    test "rejects other languages and non-binary input" do
      refute Markdown.can_validate?("lib/my_module.ex")
      refute Markdown.can_validate?("file.txt")
      refute Markdown.can_validate?(nil)
    end
  end

  describe "validate/2" do
    test "accepts a well-formed document" do
      assert {:ok, :valid} = Markdown.validate(@document)
    end

    test "accepts an empty document" do
      assert {:ok, :valid} = Markdown.validate("")
    end

    test "accepts a document with balanced fences" do
      content = "```\ncode\n```\n\n~~~\nmore\n~~~\n"
      assert {:ok, :valid} = Markdown.validate(content)
    end

    test "reports an unclosed fenced code block as a warning" do
      content = "# Title\n\n```elixir\ndef broken\n"

      assert {:error, [error]} = Markdown.validate(content)
      assert error.severity == :warning
      assert error.line == 3
      assert error.message =~ "Unclosed fenced code block"
    end

    test "does not treat indented code blocks as unclosed fences" do
      content = "# Title\n\n    indented code\n    more code\n"
      assert {:ok, :valid} = Markdown.validate(content)
    end

    test "reports an error for non-binary content" do
      assert {:error, [error]} = Markdown.validate(nil)
      assert error.severity == :error
      assert error.message =~ "must be a string"
    end
  end

  describe "integration with Ragex.Editor.Validator" do
    test "is selected for .md files" do
      assert Validator.can_validate?(path: "README.md")
      assert {:ok, :valid} = Validator.validate(@document, path: "README.md")
    end

    test "is selected for .markdown files" do
      assert Validator.can_validate?(path: "guide.markdown")
      assert {:ok, :valid} = Validator.validate("# Title", path: "guide.markdown")
    end

    test "is registered under the :markdown language" do
      assert {:ok, Markdown} = Validator.get_validator(:markdown)
    end

    test "surfaces warnings through the orchestration layer" do
      assert {:error, [error]} = Validator.validate("```\nunclosed\n", path: "README.md")
      assert error.severity == :warning
    end
  end
end
