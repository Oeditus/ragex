defmodule Ragex.MCP.Handlers.SCIPTools do
  @moduledoc """
  MCP tool definitions and handlers for SCIP bridge features.

  Provides 2 tools:
  - `scip_status` -- show available SCIP indexers, detected languages, CLI status
  - `scip_index` -- run SCIP indexer and ingest results into the knowledge graph
  """

  alias Ragex.Analyzers.SCIP.{Adapter, Indexer, Parser, Registry}

  @doc "Returns the list of SCIP tool definitions for tools/list."
  def tool_definitions do
    [
      %{
        name: "scip_status",
        description:
          "Show SCIP bridge status: available indexer binaries, detected languages in the project, " <>
            "and scip CLI availability. Use this to check what additional languages can be analyzed.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description:
                "Project directory to check for language markers (optional, defaults to cwd)"
            }
          }
        }
      },
      %{
        name: "scip_index",
        description:
          "Run a SCIP indexer for a specific language and ingest results into the knowledge graph. " <>
            "After indexing, all existing tools (search, graph, impact analysis) work with the new data.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Project directory to index"},
            language: %{
              type: "string",
              description:
                "Language to index (go, rust, java, kotlin, scala, c_cpp, csharp, ruby, dart, php). " <>
                  "If omitted, auto-detects and indexes all found languages."
            },
            from_file: %{
              type: "string",
              description:
                "Path to existing index.scip file (skip running indexer, just parse and ingest)"
            },
            generate_embeddings: %{
              type: "boolean",
              description: "Generate embeddings for SCIP-indexed code (default: false)",
              default: false
            }
          },
          required: ["path"]
        }
      }
    ]
  end

  @doc "Dispatch a SCIP tool call."
  def call_tool(name, arguments) do
    case name do
      "scip_status" -> handle_status(arguments)
      "scip_index" -> handle_index(arguments)
      _ -> {:error, "Unknown SCIP tool: #{name}"}
    end
  end

  # ── scip_status ──────────────────────────────────────────────────────

  defp handle_status(args) do
    project_dir = Map.get(args, "path", File.cwd!())

    detected = Registry.detect_languages(project_dir)
    indexers = Registry.check_indexers()
    scip_cli = Registry.scip_cli_available?()

    {:ok,
     %{
       scip_cli_available: scip_cli,
       detected_languages:
         Enum.map(detected, fn lang ->
           indexer_status = Map.get(indexers, lang.language, %{available: false})

           %{
             language: lang.language,
             marker_found: true,
             indexer: lang.indexer,
             indexer_available: indexer_status.available,
             extensions: lang.extensions
           }
         end),
       all_supported_languages:
         Enum.map(Registry.all_languages(), fn lang ->
           %{language: lang.language, indexer: lang.indexer, extensions: lang.extensions}
         end),
       existing_index: Indexer.find_existing_index(project_dir) != nil
     }}
  end

  # ── scip_index ───────────────────────────────────────────────────────

  defp handle_index(args) do
    project_dir = Map.fetch!(args, "path")
    language = Map.get(args, "language")
    from_file = Map.get(args, "from_file")
    gen_embeddings = Map.get(args, "generate_embeddings", false)

    opts = [generate_embeddings: gen_embeddings]

    cond do
      # Ingest from existing file
      from_file ->
        Adapter.ingest_from_file(project_dir, from_file, opts)

      # Index specific language
      language ->
        Adapter.index_and_ingest(project_dir, language, opts)

      # Auto-detect and index all
      true ->
        with {:ok, results} <- Indexer.index_all(project_dir, opts) do
          # Parse and ingest each successful result
          stats =
            Enum.reduce(results, %{languages: [], total_modules: 0, total_functions: 0}, fn
              {lang, {:ok, json}}, acc ->
                case Parser.parse(json, project_dir) do
                  {:ok, analysis} ->
                    {:ok, ingest_stats} = Adapter.ingest(analysis, opts)

                    %{
                      acc
                      | languages: [lang | acc.languages],
                        total_modules: acc.total_modules + ingest_stats.modules,
                        total_functions: acc.total_functions + ingest_stats.functions
                    }

                  _ ->
                    acc
                end

              {_lang, {:error, _}}, acc ->
                acc
            end)

          {:ok, stats}
        end
    end
  end
end
