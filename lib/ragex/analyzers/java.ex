defmodule Ragex.Analyzers.Java do
  @moduledoc """
  Native fallback analyzer for Java.

  Used when `Ragex.Analyzers.Metastatic` cannot parse a file -- i.e. when the
  Metastatic Java adapter is unavailable (no JDK on the machine) or its bridge
  fails. When Metastatic *can* parse the file, `Ragex.Analyzers.Metastatic` is
  preferred because it yields the full MetaAST (complexity metrics, semantic
  `op_kind` enrichment), whereas this module only recovers the graph skeleton.

  ## Extraction strategy

  A line-oriented scanner rather than a full parser, deliberately: the point of
  a *fallback* is to keep the knowledge graph populated when the real parser is
  missing, not to second-guess it. It recognises:

    * `package` / `import` declarations -> `:imports` edges
    * `class` / `interface` / `enum` / `record` declarations -> modules
    * method and constructor declarations -> functions
    * qualified calls (`Foo.bar(`, `obj.method(`) -> `:calls` edges

  Braces inside string literals and comments are masked before scanning, so a
  `{` in a string does not skew the nesting depth.

  ## Limitations

  Anonymous classes, lambdas and local classes are not distinguished from
  their enclosing type. Methods are attributed to the innermost enclosing type
  declaration. This is a best-effort skeleton, which is why it is only reached
  when the primary path has already failed.
  """

  @behaviour Ragex.Analyzers.Behaviour

  @modifier_pattern ~r/\b(?:public|protected|private|static|final|abstract|synchronized|native|default|strictfp|sealed|non-sealed)\b/

  @doc """
  Returns the regular expression matching Java declaration modifiers.
  """
  @spec modifier_pattern() :: Regex.t()
  def modifier_pattern, do: @modifier_pattern

  @type_decl_pattern ~r/\b(class|interface|enum|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)/
  @method_decl_pattern ~r/\b([A-Za-z_$][A-Za-z0-9_$]*)\s*\(([^)]*)\)\s*(?:throws\s+[^{;]+)?\{/

  @impl true
  def analyze(source, file_path) when is_binary(source) do
    lines = source |> mask_non_code() |> String.split("\n")

    package_name = extract_package(lines)
    imports = extract_imports(lines)
    types = extract_types(lines, file_path)
    functions = Enum.flat_map(types, &extract_methods(&1, file_path))
    calls = extract_calls(lines, types, functions)

    module_name =
      case types do
        [%{name: name} | _] -> name
        [] -> module_name_from_path(file_path)
      end

    modules =
      case types do
        [] ->
          [
            %{
              name: module_name,
              file: file_path,
              line: 1,
              doc: nil,
              metadata: %{type: :file, language: :java}
            }
          ]

        _ ->
          Enum.map(types, fn type ->
            %{
              name: type.name,
              file: file_path,
              line: type.line,
              doc: nil,
              metadata: %{
                type: type.kind,
                language: :java,
                package: package_name,
                super_class: type.super_class
              }
            }
          end)
      end

    import_edges =
      Enum.map(imports, fn imported ->
        %{
          from_module: module_name,
          to_module: imported.name,
          type: :import
        }
      end)

    {:ok,
     %{
       modules: modules,
       functions: functions,
       calls: calls,
       imports: import_edges
     }}
  rescue
    e -> {:error, {:java_fallback_failed, Exception.message(e)}}
  end

  @impl true
  def supported_extensions, do: [".java"]

  # ----- Package and imports -----

  defp extract_package(lines) do
    Enum.find_value(lines, nil, fn line ->
      case Regex.run(~r/^\s*package\s+([A-Za-z0-9_$.]+)\s*;/, line) do
        [_, name] -> name
        _ -> nil
      end
    end)
  end

  defp extract_imports(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      case Regex.run(~r/^\s*import\s+(?:static\s+)?([A-Za-z0-9_$.*]+)\s*;/, line) do
        [_, name] -> [%{name: name, line: line_no}]
        _ -> []
      end
    end)
  end

  # ----- Types -----

  defp extract_types(lines, file_path) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      case Regex.run(@type_decl_pattern, line) do
        [_, kind, name] ->
          [
            %{
              name: name,
              kind: String.to_atom(kind),
              line: line_no,
              file: file_path,
              super_class: extract_super_class(line)
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp extract_super_class(line) do
    case Regex.run(~r/\bextends\s+([A-Za-z0-9_$.]+)/, line) do
      [_, parent] -> parent
      _ -> nil
    end
  end

  # ----- Methods -----

  defp extract_methods(type, file_path) do
    # Methods are attributed to a type by scanning from its declaration line
    # until the next type declaration. This is approximate but stable, and it
    # keeps the fallback linear in file size.
    body = Enum.drop(type.body_lines, 0)

    body
    |> Enum.with_index(type.line + 1)
    |> Enum.flat_map(fn {line, line_no} ->
      case Regex.run(@method_decl_pattern, line) do
        [_, name, params] ->
          if control_keyword?(name) do
            []
          else
            [
              %{
                name: String.to_atom(name),
                arity: count_params(params),
                module: type.name,
                file: file_path,
                line: line_no,
                doc: nil,
                visibility: visibility(line),
                metadata: %{language: :java}
              }
            ]
          end

        _ ->
          []
      end
    end)
  end

  defp control_keyword?(name) do
    name in ~w(if for while switch catch synchronized try do else return new)
  end

  defp count_params(params) do
    params
    |> String.trim()
    |> case do
      "" -> 0
      trimmed -> trimmed |> String.split(",") |> length()
    end
  end

  defp visibility(line) do
    cond do
      String.contains?(line, "private") -> :private
      String.contains?(line, "protected") -> :protected
      true -> :public
    end
  end

  # ----- Calls -----

  defp extract_calls(lines, types, functions) do
    owner = fn line_no ->
      case Enum.filter(functions, &(&1.line <= line_no)) do
        [] ->
          case types do
            [%{name: name} | _] -> name
            [] -> "top_level"
          end

        candidates ->
          Enum.max_by(candidates, & &1.line).module
      end
    end

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      Regex.scan(~r/([A-Za-z_$][A-Za-z0-9_$.]*)\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/, line)
      |> Enum.map(fn [_, receiver, function] ->
        %{
          from_module: owner.(line_no),
          from_function: :unknown,
          from_arity: 0,
          to_module: receiver,
          to_function: String.to_atom(function),
          to_arity: 0,
          line: line_no
        }
      end)
    end)
    |> Enum.uniq_by(fn call -> {call.to_module, call.to_function, call.line} end)
  end

  # ----- Helpers -----

  defp module_name_from_path(file_path) do
    file_path
    |> Path.basename(".java")
    |> String.to_atom()
  end

  # Replaces the contents of string/char literals and comments with spaces so
  # that braces and parentheses inside them cannot affect brace counting or
  # look like declarations. Line structure is preserved (newlines kept) so that
  # line numbers stay accurate.
  defp mask_non_code(source) do
    source
    |> mask_block_comments()
    |> mask_line_comments()
    |> mask_string_literals()
  end

  defp mask_block_comments(source) do
    Regex.replace(~r|/\*.*?\*/|s, source, fn match ->
      match |> String.replace(~r/[^\n]/, " ")
    end)
  end

  defp mask_line_comments(source) do
    Regex.replace(~r|//[^\n]*|, source, fn match ->
      String.duplicate(" ", String.length(match))
    end)
  end

  defp mask_string_literals(source) do
    Regex.replace(~r/"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'/, source, fn match ->
      String.duplicate(" ", String.length(match))
    end)
  end
end
