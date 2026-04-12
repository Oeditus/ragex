defmodule Ragex.Embeddings.TextGenerator do
  @moduledoc """
  Generates embeddable text descriptions from code entities.

  Converts modules, functions, and other code entities into natural language
  descriptions suitable for embedding generation and semantic search.

  Functions enriched with MetaAST metadata (from `Ragex.Analyzers.Metastatic`)
  include additional semantic context in their text:
  - `async: true` -- annotated as "async function"
  - `is_macro: true` -- annotated as "macro"
  - `decorators: [...]` -- decorator names listed
  - `guards: ...` -- annotated as "with guards"
  - `type_annotations: [...]` -- type information listed
  """

  @doc """
  Generates text description for a module.

  Includes module name, documentation, and metadata.
  """
  def module_text(module_data) do
    parts = [
      "Module: #{module_name_to_string(module_data.name)}",
      if(module_data[:doc], do: "Documentation: #{module_data.doc}", else: nil),
      "File: #{module_data.file}",
      if(module_data[:metadata][:type], do: "Type: #{module_data.metadata.type}", else: nil),
      if(module_data[:metadata][:container_type],
        do: "Container type: #{module_data.metadata.container_type}",
        else: nil
      )
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join(". ")
  end

  @doc """
  Generates text description for a function.

  Includes function signature, module context, documentation, visibility, and
  any MetaAST semantic metadata (async, macro, guards, decorators, annotations).
  """
  def function_text(function_data) do
    signature = function_signature(function_data)
    meta = Map.get(function_data, :metadata, %{})
    metastatic = Map.get(meta, :metastatic, %{})

    parts = [
      "Function: #{signature}",
      "Module: #{module_name_to_string(function_data.module)}",
      if(function_data[:doc], do: "Documentation: #{function_data.doc}", else: nil),
      "Visibility: #{function_data.visibility}",
      "File: #{function_data.file}:#{function_data.line}",
      metastatic_hint(metastatic)
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join(". ")
  end

  # Build a short semantic hint string from MetaAST enrichment data.
  # Returns nil when there is no enrichment to describe.
  defp metastatic_hint(metastatic) when is_map(metastatic) and map_size(metastatic) > 0 do
    hints = []

    hints =
      if Map.get(metastatic, :async) == true do
        ["async" | hints]
      else
        hints
      end

    hints =
      if Map.get(metastatic, :is_macro) == true do
        ["macro" | hints]
      else
        hints
      end

    hints =
      case Map.get(metastatic, :guards) do
        nil -> hints
        _guard -> ["with guards" | hints]
      end

    hints =
      case Map.get(metastatic, :decorators) do
        nil ->
          hints

        [] ->
          hints

        decorators when is_list(decorators) ->
          ["decorators: #{Enum.join(decorators, ", ")}" | hints]
      end

    hints =
      case Map.get(metastatic, :multi_clause) do
        true ->
          clauses = Map.get(metastatic, :clauses, [])
          ["#{length(clauses)} clauses" | hints]

        _ ->
          hints
      end

    case hints do
      [] -> nil
      _ -> "Attributes: #{Enum.join(Enum.reverse(hints), ", ")}"
    end
  end

  defp metastatic_hint(_), do: nil

  @doc """
  Generates text description for a function with its body/implementation.

  Includes signature and code snippet for more detailed semantic search.
  """
  def function_with_code_text(function_data, code_snippet) do
    base_text = function_text(function_data)

    # Truncate code snippet to reasonable length
    code = String.slice(code_snippet || "", 0, 1000)

    if String.length(code) > 0 do
      base_text <> ". Code: " <> code
    else
      base_text
    end
  end

  @doc """
  Generates text for a call relationship.

  Describes which function calls which other function.
  """
  def call_text(call_data) do
    from_sig =
      "#{module_name_to_string(call_data.from_module)}.#{call_data.from_function}/#{call_data.from_arity}"

    to_sig =
      "#{module_name_to_string(call_data.to_module)}.#{call_data.to_function}/#{call_data.to_arity}"

    "Function call: #{from_sig} calls #{to_sig}"
  end

  @doc """
  Generates text for an import relationship.

  Describes which module imports which other module.
  """
  def import_text(import_data) do
    "Import: #{module_name_to_string(import_data.from_module)} imports #{module_name_to_string(import_data.to_module)}"
  end

  # Private helpers

  defp function_signature(function_data) do
    "#{module_name_to_string(function_data.name)}/#{function_data.arity}"
  end

  defp module_name_to_string(name) when is_atom(name), do: Atom.to_string(name)
  defp module_name_to_string(name) when is_binary(name), do: name

  defp module_name_to_string({mod, name, arity}) when is_atom(mod) and is_atom(name) do
    "#{Atom.to_string(mod)}.#{Atom.to_string(name)}/#{arity}"
  end

  defp module_name_to_string(name), do: inspect(name)
end
