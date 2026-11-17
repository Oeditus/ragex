defmodule Ragex.Plugins.Languages.Elixir.Propwise do
  @moduledoc """
  Bridge to [PropWise](https://hexdocs.pm/propwise), an AST-based analyzer that
  finds functions worth property-based testing in Elixir codebases.

  PropWise reports, per function: purity (`:pure` / `:unknown` / `:impure`),
  detected patterns (collection operations, validation, encoders, ...), inferred
  algebraic laws (associativity, round-trip, involution, ...), whether the
  function participates in an inverse pair (`encode`/`decode`), a score, and
  ready-to-paste StreamData/PropEr properties.

  ## Optional dependency

  PropWise is not a Ragex dependency. `available?/1` probes for it and `run/1`
  degrades to an actionable error when it is missing, mirroring
  `Ragex.Analysis.Prisma`. The tool is still advertised -- a user who has
  PropWise installed in the analysed project must be able to find it -- but the
  error message says exactly what to add to `mix.exs`.

  ## Reporting `total_functions` honestly

  PropWise parses with Metastatic. When its parser cannot see function
  definitions it reports `total_functions: 0`, which is indistinguishable from
  "this project is clean" unless it is surfaced. This bridge therefore passes
  the count through verbatim and the tool description warns about it.
  """

  @type candidate :: %{
          module: String.t(),
          function: String.t(),
          arity: non_neg_integer(),
          file: String.t(),
          line: pos_integer(),
          purity: :pure | :unknown | :impure,
          patterns: [atom()],
          laws: [atom()],
          score: non_neg_integer(),
          rank: pos_integer(),
          inverse_pair: boolean(),
          suggestions: [String.t()],
          source: :propwise
        }

  @doc "Returns the MCP tool schema for `propwise_analyze`."
  @spec tool_schema() :: Ragex.Plugin.tool_schema()
  def tool_schema do
    %{
      name: "propwise_analyze",
      description:
        "Find functions that would benefit from property-based testing (PropWise). " <>
          "Reports purity, detected patterns, inferred algebraic laws, inverse function " <>
          "pairs, and ready-to-paste StreamData/PropEr properties. " <>
          "NOTE: `total_functions` is reported verbatim; a value of 0 means the parser " <>
          "found no function definitions, not that the code is clean.",
      inputSchema: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Project directory or single Elixir file to analyze",
            default: "."
          },
          min_score: %{
            type: "integer",
            description: "Minimum score for a function to be reported as a candidate",
            default: 4
          },
          library: %{
            type: "string",
            description: "Property-testing library to generate suggestions for",
            enum: ["stream_data", "proper"],
            default: "stream_data"
          },
          format: %{
            type: "string",
            description: "Output verbosity",
            enum: ["summary", "detailed", "suggestions"],
            default: "summary"
          }
        },
        required: ["path"]
      },
      destruction_level: :none
    }
  end

  @doc """
  Returns whether PropWise is loadable.

  This is a process-local probe: PropWise must be a dependency of the *Ragex*
  VM, not merely of the analysed project. When it is only present in the
  analysed project, `run/1` reports the same actionable error.
  """
  @spec available?(String.t()) :: boolean()
  def available?(_path \\ "."), do: Code.ensure_loaded?(Module.concat([PropWise]))

  @doc """
  Runs PropWise and returns normalized findings.

  ## Formats

    * `"summary"` -- counts only, no per-candidate payload
    * `"detailed"` -- every candidate with its metadata
    * `"suggestions"` -- only the generated property code
  """
  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(%{"path" => path} = params) when is_binary(path) do
    if available?() do
      opts = [
        min_score: Map.get(params, "min_score", 4),
        library: parse_library(Map.get(params, "library", "stream_data"))
      ]

      # Resolved at call time rather than compile time: PropWise is an optional
      # dependency, so a direct `PropWise.analyze/2` call would emit an
      # undefined-module warning in every build that does not have it.
      propwise = Module.concat([PropWise])

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      result = apply(propwise, :analyze, [path, opts])

      result
      |> normalize()
      |> format(Map.get(params, "format", "summary"))
    else
      {:error, unavailable_message()}
    end
  end

  def run(_params), do: {:error, "propwise_analyze requires a \"path\" argument"}

  defp unavailable_message do
    "PropWise is not available to Ragex. Add {:propwise, \"~> 0.5\", only: [:dev, :test], " <>
      "runtime: false} to the analysed project's mix.exs (and to Ragex's, if you want it " <>
      "loaded in-process), then re-run."
  end

  defp parse_library("proper"), do: :proper
  defp parse_library(_), do: :stream_data

  # ----- Normalization -------------------------------------------------------

  defp normalize(result) do
    %{
      total_functions: result.total_functions,
      candidates_count: result.candidates_count,
      dropped_count: result.dropped_count,
      purity_counts: result.purity_counts,
      inverse_pairs: result.inverse_pairs,
      candidates: Enum.map(result.candidates, &normalize_candidate/1)
    }
  end

  defp normalize_candidate(candidate) do
    %{
      module: candidate.module,
      function: to_string(candidate.name),
      arity: candidate.arity,
      file: candidate.file,
      line: candidate.line,
      purity: candidate.purity,
      patterns: Enum.map(candidate.patterns, fn {type, _reason} -> type end),
      laws: candidate.laws,
      score: candidate.score,
      rank: candidate.rank,
      inverse_pair: candidate.inverse_pair,
      suggestions: candidate.suggestions,
      source: :propwise
    }
  end

  # ----- Formatting ----------------------------------------------------------

  defp format(data, "summary") do
    {:ok,
     %{
       status: "success",
       source: "propwise",
       total_functions: data.total_functions,
       candidates_count: data.candidates_count,
       dropped_count: data.dropped_count,
       purity_counts: data.purity_counts,
       inverse_pairs_count: length(data.inverse_pairs)
     }}
  end

  defp format(data, "detailed") do
    {:ok, Map.put(data, :status, "success")}
  end

  defp format(data, "suggestions") do
    {:ok,
     %{
       status: "success",
       source: "propwise",
       suggestions:
         Enum.map(data.candidates, fn candidate ->
           %{
             module: candidate.module,
             function: candidate.function,
             arity: candidate.arity,
             file: candidate.file,
             line: candidate.line,
             properties: candidate.suggestions
           }
         end)
     }}
  end

  defp format(_data, other), do: {:error, "Unknown format: #{inspect(other)}"}
end
