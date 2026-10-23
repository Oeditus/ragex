defmodule Ragex.NodeFormatter do
  @moduledoc """
  Renders knowledge-graph node identifiers as human-readable strings.

  Graph nodes appear in several shapes depending on where they came from:

    * a bare atom — a module name
    * `{module, name, arity}` — a function reference
    * `{:module, id}` / `{:function, module, name, arity}` — tagged variants
      produced by some graph queries

  This module is the single place that knows how to turn any of those into a
  string. Previously three near-identical private copies existed (in the MCP
  `Resources` and `Tools` handlers and in `Ragex.RAG.ContextBuilder`) and had
  already drifted apart, so the same node could render differently depending on
  which code path reached it.

  ## Styles

  Two rendering styles are supported, because the two audiences have different
  expectations:

    * `:mcp` (default) — the form MCP clients see. Modules are rendered with
      `Atom.to_string/1`, so `MyApp.Foo` becomes `"Elixir.MyApp.Foo"`, matching
      the identifiers clients send back in requests. `nil` is inspected like any
      other unexpected value.

    * `:prompt` — the form embedded in LLM prompts by the RAG pipeline. Modules
      are rendered with `inspect/1`, so `MyApp.Foo` becomes `"MyApp.Foo"` without
      the `Elixir.` prefix, which reads better in prose. `nil` stays `nil` so
      callers can use `|| "Unknown"` to substitute a default.

  ## Examples

      iex> Ragex.NodeFormatter.format_node_id(MyApp.Foo)
      "Elixir.MyApp.Foo"

      iex> Ragex.NodeFormatter.format_node_id({MyApp.Foo, :bar, 2})
      "Elixir.MyApp.Foo.bar/2"

      iex> Ragex.NodeFormatter.format_node_id({:function, MyApp.Foo, :bar, 2})
      "Elixir.MyApp.Foo.bar/2"

      iex> Ragex.NodeFormatter.format_node_id({MyApp.Foo, :bar, 2}, :prompt)
      "MyApp.Foo.bar/2"

      iex> Ragex.NodeFormatter.format_node_id(nil, :prompt)
      nil
  """

  @type style :: :mcp | :prompt

  @doc """
  Formats a graph node identifier.

  ## Parameters
  - `node` — the node identifier in any supported shape
  - `style` — `:mcp` (default) or `:prompt`, see the module docs

  ## Returns
  A string, or `nil` when `node` is `nil` and `style` is `:prompt`.
  """
  @spec format_node_id(term(), style()) :: String.t() | nil
  def format_node_id(node, style \\ :mcp)

  # `:prompt` style preserves `nil` so callers can substitute a default.
  def format_node_id(nil, :prompt), do: nil

  # Binary identifiers are already in their final form; return as-is.
  def format_node_id(node, _style) when is_binary(node), do: node

  def format_node_id(node, style) when is_atom(node), do: format_module(node, style)

  def format_node_id({module, name, arity}, style)
      when is_atom(module) and is_atom(name) and is_integer(arity) do
    "#{format_module(module, style)}.#{Atom.to_string(name)}/#{arity}"
  end

  def format_node_id({:module, id}, style), do: "module:#{format_node_id(id, style)}"

  def format_node_id({:function, module, name, arity}, style) do
    format_node_id({module, name, arity}, style)
  end

  def format_node_id(node, _style), do: inspect(node)

  # `:mcp` keeps the `Elixir.` prefix so identifiers round-trip with clients;
  # `:prompt` drops it because it reads as noise in prose.
  defp format_module(module, :mcp), do: Atom.to_string(module)
  defp format_module(module, :prompt), do: inspect(module)
end
