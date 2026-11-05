defmodule Ragex.Analyzers.Metastatic do
  @moduledoc """
  Language-agnostic analyzer using Metastatic MetaAST.

  Primary entity extraction via `Ragex.Analyzers.MetaASTExtractor`, enriched
  with per-function complexity metrics from `MetaCredo.Analysis.Complexity`.
  Falls back to native language analyzers when Metastatic parsing fails and
  the `:fallback_to_native_analyzers` feature flag is enabled.

  ## Enrichment

  Each function in the analysis result is enriched with a `:metastatic` key:

      %{
  - **Modules** -- `:container` nodes with `container_type: :module` or `:class`
  - **Functions** -- `:function_def` nodes with name, arity, visibility
  - **Calls** -- `:function_call` nodes with caller/callee resolution
  - **Imports** -- `:import` nodes with source and import type

  ## Documentation Languages

  Markdown documents carry no callable entities, so `MetaASTExtractor`
  legitimately returns empty collections for them. `analyze/2` therefore
  materialises a single *document* module (named after the file's base name)
  so the file is still indexed, searchable and connected to the graph instead
  of silently vanishing from an analysis run.

  ## Usage
        }
      }
  """

  @behaviour Ragex.Analyzers.Behaviour

  require Logger
  alias MetaCredo.Analysis.Complexity
  alias Metastatic.Document
  alias Ragex.Analyzers.MetaASTExtractor

  @impl true
  def analyze(source, file_path) do
    language = detect_language(file_path)

    case Ragex.LanguageSupport.parse_document(source, language) do
      {:ok, doc} ->
        doc
        |> analyze_via_meta_ast(file_path)
        |> ensure_document_entity(file_path, language)

      {:error, reason} ->
        Logger.warning(
          "Metastatic parsing failed for #{file_path}: #{inspect(reason)}. " <>
            "Falling back to native analyzer."
        )

        fallback_analyze(source, file_path, language)
    end
  end

  @impl true
  def supported_extensions do
    Ragex.LanguageSupport.metastatic_extensions()
  end

  # Private

  defp detect_language(file_path), do: Ragex.LanguageSupport.detect_language(file_path)

  # Primary path: extract entities from MetaAST, then enrich with metrics.
  defp analyze_via_meta_ast(%Document{} = doc, file_path) do
    case MetaASTExtractor.extract(doc, file_path) do
      {:ok, analysis} ->
        try do
          {:ok, enrich_analysis(analysis, doc)}
        rescue
          e ->
            Logger.warning("MetaAST enrichment failed for #{file_path}: #{Exception.message(e)}")
            {:ok, analysis}
        end

      {:error, reason} ->
        Logger.warning("MetaAST extraction failed for #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp enrich_analysis(analysis, %Document{ast: meta_ast, metadata: metadata} = doc) do
    language = doc.language || :unknown
    function_data = extract_function_data(meta_ast)
    container_data = extract_container_data(meta_ast, language)

    enriched_functions =
      Enum.map(analysis.functions, fn func ->
        case Map.get(function_data, {func.name, func.arity}) ||
               Map.get(function_data, func.name) ||
               Map.get(function_data, to_string(func.name)) do
          nil ->
            func

          {func_node, _body, _meta} ->
            metrics = calculate_function_metrics(func_node, language)
            ast_serialized = safe_meta_ast_to_json(func_node)
            metadata = Map.merge(func.metadata, %{metastatic: metrics})

            func
            |> Map.merge(%{
              metadata: metadata,
              ast_serialized: ast_serialized
            })
        end
      end)

    enriched_modules =
      Enum.map(analysis.modules, fn mod ->
        case Map.get(container_data, mod.name) do
          nil ->
            mod

          container_node ->
            ast_serialized = safe_meta_ast_to_json(container_node)
            Map.put(mod, :ast_serialized, ast_serialized)
        end
      end)

    analysis
    |> Map.put(:functions, enriched_functions)
    |> Map.put(:modules, enriched_modules)
    |> Map.put(:meta_ast, meta_ast)
    |> Map.put(:meta_ast_metadata, metadata)
  end

  defp extract_function_data(meta_ast) do
    meta_ast
    |> extract_all_functions()
    |> Map.new()
  end

  defp extract_all_functions(ast, acc \\ []) do
    case ast do
      {:function_def, meta, body} when is_list(meta) ->
        case Keyword.get(meta, :name) do
          name when is_binary(name) or is_atom(name) ->
            func_name = safe_to_atom(name)
            params = Keyword.get(meta, :params, [])
            arity = length(params)

            metadata = %{
              function_name: to_string(name),
              params: params,
              visibility: Keyword.get(meta, :visibility, :public),
              body: body
            }

            entry = {{:function_def, meta, body}, body, metadata}

            [
              {{func_name, arity}, entry},
              {{to_string(name), arity}, entry},
              {func_name, entry},
              {to_string(name), entry}
              | acc
            ]

          _ ->
            acc
        end

      {:container, _meta, body} when is_list(body) ->
        Enum.reduce(body, acc, &extract_all_functions/2)

      {:block, _meta, statements} when is_list(statements) ->
        Enum.reduce(statements, acc, &extract_all_functions/2)

      {_type, _meta, children} when is_list(children) ->
        Enum.reduce(children, acc, &extract_all_functions/2)

      list when is_list(list) ->
        Enum.reduce(list, acc, &extract_all_functions/2)

      _ ->
        acc
    end
  end

  defp extract_container_data(meta_ast, language) do
    meta_ast
    |> collect_containers(language, [])
    |> Map.new()
  end

  defp collect_containers(ast, language, acc) do
    case ast do
      {:container, meta, body} when is_list(meta) and is_list(body) ->
        acc =
          case Keyword.get(meta, :name) do
            name when is_binary(name) ->
              mod_name = normalize_module_name(name, language)
              [{mod_name, {:container, meta, body}} | acc]

            _ ->
              acc
          end

        Enum.reduce(body, acc, &collect_containers(&1, language, &2))

      {:block, _meta, statements} when is_list(statements) ->
        Enum.reduce(statements, acc, &collect_containers(&1, language, &2))

      {_type, _meta, children} when is_list(children) ->
        Enum.reduce(children, acc, &collect_containers(&1, language, &2))

      list when is_list(list) ->
        Enum.reduce(list, acc, &collect_containers(&1, language, &2))

      _ ->
        acc
    end
  end

  defp normalize_module_name(name, :elixir) when is_binary(name) do
    name
    |> String.split(".")
    |> Enum.map(&safe_to_atom/1)
    |> Module.concat()
  end

  defp normalize_module_name(name, :erlang) when is_binary(name) do
    safe_to_atom(name)
  end

  defp normalize_module_name(name, _language), do: name

  @max_atom_length 255

  defp safe_to_atom(atom) when is_atom(atom), do: atom

  defp safe_to_atom(str) when is_binary(str) do
    if String.length(str) > @max_atom_length do
      str |> String.slice(0, @max_atom_length) |> String.to_atom()
    else
      String.to_atom(str)
    end
  end

  defp calculate_function_metrics(ast_node, language) do
    doc = Document.new(ast_node, language)

    case Complexity.analyze(doc) do
      {:ok, complexity} ->
        %{
          cyclomatic: complexity.cyclomatic,
          cognitive: complexity.cognitive,
          max_nesting: complexity.max_nesting,
          halstead: complexity.halstead,
          loc: complexity.loc,
          function_metrics: complexity.function_metrics
        }

      {:error, _reason} ->
        %{
          cyclomatic: 1,
          cognitive: 0,
          max_nesting: 0,
          halstead: %{},
          loc: %{},
          function_metrics: %{}
        }
    end
  end

  defp fallback_analyze(source, file_path, language) do
    fallback? =
      Application.get_env(:ragex, :features, [])
      |> Keyword.get(:fallback_to_native_analyzers, true)

    cond do
      Ragex.LanguageSupport.documentation_language?(language) ->
        {:ok, document_analysis(file_path, language)}

      fallback? ->
        case Ragex.Languages.native_analyzer(language) do
          nil -> {:error, :no_fallback_analyzer}
          analyzer -> analyzer.analyze(source, file_path)
        end

      true ->
        {:error, :metastatic_failed_no_fallback}
    end
  end

  # Documentation languages (Markdown) have no functions, calls or imports by
  # definition, so the MetaAST path legitimately yields empty collections.
  # Materialise a single document entity instead, so the file still lands in
  # the knowledge graph and stays discoverable via search.
  defp ensure_document_entity({:ok, analysis}, file_path, language) do
    if Ragex.LanguageSupport.documentation_language?(language) do
      {:ok, %{analysis | modules: [document_entity(file_path, language)]}}
    else
      {:ok, analysis}
    end
  end

  defp ensure_document_entity(error, _file_path, _language), do: error

  defp document_analysis(file_path, language) do
    %{
      modules: [document_entity(file_path, language)],
      functions: [],
      calls: [],
      imports: []
    }
  end

  defp document_entity(file_path, language) do
    %{
      name: document_entity_name(file_path),
      file: file_path,
      line: 1,
      doc: nil,
      metadata: %{container_type: :document, language: language}
    }
  end

  defp document_entity_name(file_path) do
    file_path
    |> Path.basename()
    |> Path.rootname()
    |> String.replace(~r/[^A-Za-z0-9_]/, "_")
  end

  defp safe_meta_ast_to_json(node) do
    node
    |> sanitize_ast_node()
    |> Dllb.MetaAST.to_json_string()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp sanitize_ast_node(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      sanitize_utf8_bytes(binary, <<>>)
    end
  end

  defp sanitize_ast_node(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&sanitize_ast_node/1)
    |> List.to_tuple()
  end

  defp sanitize_ast_node(list) when is_list(list) do
    Enum.map(list, &sanitize_ast_node/1)
  end

  defp sanitize_ast_node(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {sanitize_ast_node(k), sanitize_ast_node(v)}
    end)
  end

  defp sanitize_ast_node(other), do: other

  defp sanitize_utf8_bytes(<<>>, acc), do: acc

  defp sanitize_utf8_bytes(<<c::utf8, rest::binary>>, acc) do
    sanitize_utf8_bytes(rest, <<acc::binary, c::utf8>>)
  end

  defp sanitize_utf8_bytes(<<_byte, rest::binary>>, acc) do
    # Replace invalid byte with U+FFFD REPLACEMENT CHARACTER
    sanitize_utf8_bytes(rest, <<acc::binary, 0xEF, 0xBF, 0xBD>>)
  end
end
