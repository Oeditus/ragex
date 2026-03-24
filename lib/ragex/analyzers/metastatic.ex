defmodule Ragex.Analyzers.Metastatic do
  @moduledoc """
  Language-agnostic analyzer using Metastatic MetaAST.

  Primary entity extraction via `Ragex.Analyzers.MetaASTExtractor`, enriched
  with per-function complexity metrics from `Metastatic.Analysis.Complexity`.
  Falls back to native language analyzers when Metastatic parsing fails and
  the `:fallback_to_native_analyzers` feature flag is enabled.

  ## Enrichment

  Each function in the analysis result is enriched with a `:metastatic` key:

      %{
        metastatic: %{
          cyclomatic: 3,
          cognitive: 2,
          max_nesting: 1,
          halstead: %{volume: 50.0, difficulty: 2.5, ...},
          loc: %{physical: 10, logical: 8, ...},
          function_metrics: %{statement_count: 8, ...}
        }
      }
  """

  @behaviour Ragex.Analyzers.Behaviour

  require Logger
  alias Metastatic.{Analysis.Complexity, Builder, Document}
  alias Ragex.Analyzers.MetaASTExtractor

  alias Ragex.Analyzers.Elixir, as: ExAnalyzer
  alias Ragex.Analyzers.Erlang, as: ErlAnalyzer
  alias Ragex.Analyzers.Python, as: PyAnalyzer
  alias Ragex.Analyzers.Ruby, as: RbAnalyzer

  @impl true
  def analyze(source, file_path) do
    language = detect_language(file_path)

    case Builder.from_source(source, language) do
      {:ok, doc} ->
        analyze_via_meta_ast(doc, file_path)

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
        {:ok, enrich_analysis(analysis, doc)}

      {:error, reason} ->
        Logger.warning("MetaAST extraction failed for #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp enrich_analysis(analysis, %Document{ast: meta_ast, metadata: metadata}) do
    function_data = extract_function_data(meta_ast)

    enriched_functions =
      Enum.map(analysis.functions, fn func ->
        case Map.get(function_data, func.name) do
          nil ->
            func

          {body, _meta} ->
            metrics = calculate_function_metrics(body)
            metadata = Map.merge(func.metadata, %{metastatic: metrics})
            %{func | metadata: metadata}
        end
      end)

    analysis
    |> Map.put(:functions, enriched_functions)
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
          name when is_binary(name) ->
            func_name = String.to_atom(name)

            metadata = %{
              function_name: name,
              params: Keyword.get(meta, :params, []),
              visibility: Keyword.get(meta, :visibility, :public),
              body: body
            }

            [{func_name, {body, metadata}} | acc]

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

  defp calculate_function_metrics(ast_node) do
    doc = Document.new(ast_node, :elixir)

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
    if Application.get_env(:ragex, :features)[:fallback_to_native_analyzers] do
      case language do
        :elixir -> ExAnalyzer.analyze(source, file_path)
        :erlang -> ErlAnalyzer.analyze(source, file_path)
        :python -> PyAnalyzer.analyze(source, file_path)
        :ruby -> RbAnalyzer.analyze(source, file_path)
        _ -> {:error, :no_fallback_analyzer}
      end
    else
      {:error, :metastatic_failed_no_fallback}
    end
  end
end
