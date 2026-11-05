defmodule Ragex.Editor.Validators.Markdown do
  @moduledoc """
  Markdown document validator.

  Validates Markdown by round-tripping it through Metastatic's Markdown
  adapter (`Metastatic.Adapters.Markdown`), which is a pure-Elixir,
  dependency-free parser -- no external toolchain is required.

  The check is deliberately *structural* rather than stylistic: Markdown is
  famously permissive, so almost any byte sequence "parses". What this
  validator reports are the failures that actually break a document:

    * the source cannot be parsed at all (adapter returns an error), and
    * the document parses but cannot be reified back into Markdown, which
      indicates a malformed block-level construct.

  Unclosed fenced code blocks are reported as warnings, because most
  renderers silently swallow the rest of the document in that case.

  ## Examples

      iex> Ragex.Editor.Validators.Markdown.validate("# Title\\n\\nBody text.")
      {:ok, :valid}

      iex> Ragex.Editor.Validators.Markdown.can_validate?("README.md")
      true
  """

  @behaviour Ragex.Editor.Validator

  alias Metastatic.Adapters.Markdown, as: MarkdownAdapter
  alias Ragex.Editor.Types

  @markdown_extensions ~w(.md .markdown)

  @impl true
  @spec validate(String.t(), keyword()) ::
          {:ok, :valid} | {:error, [Types.validation_error()]}
  def validate(content, opts \\ [])

  def validate(content, _opts) when is_binary(content) do
    with {:ok, cst} <- MarkdownAdapter.parse(content),
         {:ok, meta_ast, metadata} <- MarkdownAdapter.to_meta(cst),
         {:ok, _cst} <- MarkdownAdapter.from_meta(meta_ast, metadata) do
      case unclosed_fence_line(content) do
        nil -> {:ok, :valid}
        line -> {:error, [warning("Unclosed fenced code block", line)]}
      end
    else
      {:error, reason} -> {:error, [error(reason)]}
    end
  end

  def validate(_content, _opts) do
    {:error, [error("Markdown content must be a string")]}
  end

  @impl true
  @spec can_validate?(String.t()) :: boolean()
  def can_validate?(path) when is_binary(path) do
    Path.extname(path) in @markdown_extensions
  end

  def can_validate?(_), do: false

  # Private functions

  # Returns the 1-based line of the last unterminated fence opener, or `nil`
  # when every fence is balanced. Indented code blocks are ignored on purpose:
  # they have no explicit terminator and therefore cannot be "unclosed".
  defp unclosed_fence_line(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce(nil, fn {line, number}, open_at ->
      if fence_line?(line), do: if(open_at, do: nil, else: number), else: open_at
    end)
  end

  defp fence_line?(line) do
    trimmed = String.trim_leading(line)
    String.starts_with?(trimmed, "```") or String.starts_with?(trimmed, "~~~")
  end

  defp error(message), do: Types.validation_error(message, severity: :error)
  defp warning(message, line), do: Types.validation_error(message, line: line, severity: :warning)
end
