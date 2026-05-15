defmodule Mix.Tasks.Ragex.Status do
  @shortdoc "Show Ragex system status and health check"
  @moduledoc """
  Displays comprehensive status of the Ragex system.

  Shows index health, embedding model status, git enrichment status,
  editor configs found, and SCIP indexer availability.

  ## Usage

      mix ragex.status

  ## Output Sections

  - **Knowledge Graph** -- node/edge counts by type
  - **Embeddings** -- model loaded, vector count
  - **Git** -- backend, enrichment status
  - **Editors** -- detected editor configs
  - **SCIP** -- available indexers, detected languages
  """

  use Mix.Task

  alias Ragex.Analyzers.SCIP.Registry, as: SCIPRegistry
  alias Ragex.CLI.EditorConfig
  alias Ragex.Embeddings.Bumblebee, as: EmbeddingModel
  alias Ragex.Git.{Backend, Repo}
  alias Ragex.Graph.Store

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start", ["--no-start"])

    # Start minimal required services
    {:ok, _} = Application.ensure_all_started(:ragex)

    project_dir = File.cwd!()

    Mix.shell().info("\nRagex Status")
    Mix.shell().info("============\n")

    show_graph_status()
    show_embedding_status()
    show_git_status(project_dir)
    show_editor_status(project_dir)
    show_scip_status(project_dir)

    Mix.shell().info("")
  end

  defp show_graph_status do
    stats = Store.stats()

    Mix.shell().info("Knowledge Graph:")
    Mix.shell().info("  Nodes: #{stats.nodes}")
    Mix.shell().info("  Edges: #{stats.edges}")
    Mix.shell().info("  Embeddings: #{stats.embeddings}")

    if stats.nodes > 0 do
      modules = Store.count_nodes_by_type(:module)
      functions = Store.count_nodes_by_type(:function)
      Mix.shell().info("  Modules: #{modules}, Functions: #{functions}")
    end

    Mix.shell().info("")
  end

  defp show_embedding_status do
    Mix.shell().info("Embedding Model:")

    ready =
      try do
        EmbeddingModel.ready?()
      rescue
        _ -> false
      end

    Mix.shell().info("  Model loaded: #{ready}")
    Mix.shell().info("")
  end

  defp show_git_status(project_dir) do
    Mix.shell().info("Git Integration:")

    git_available = Repo.git_available?()
    Mix.shell().info("  git CLI: #{if git_available, do: "available", else: "not found"}")

    backend = Backend.active()
    Mix.shell().info("  Backend: #{inspect(backend)}")

    egit = Backend.egit_available?()
    Mix.shell().info("  egit NIF: #{if egit, do: "loaded", else: "not available (optional)"}")

    if git_available do
      case Repo.root(project_dir) do
        {:ok, root} ->
          Mix.shell().info("  Repo root: #{root}")

          case Repo.current_branch(project_dir) do
            {:ok, branch} -> Mix.shell().info("  Branch: #{branch}")
            _ -> :ok
          end

        _ ->
          Mix.shell().info("  Not a git repository")
      end
    end

    Mix.shell().info("")
  end

  defp show_editor_status(project_dir) do
    Mix.shell().info("Editor Configs:")

    detected = EditorConfig.detect_editors(project_dir)

    if detected == [] do
      Mix.shell().info("  None detected. Run `mix ragex.setup` to configure.")
    else
      Enum.each(detected, fn {_key, info} ->
        path = Path.join(project_dir, info.config_path)
        has_ragex = check_has_ragex(path)
        status = if has_ragex, do: "ragex configured", else: "no ragex entry"
        Mix.shell().info("  #{info.name}: #{info.config_path} (#{status})")
      end)
    end

    Mix.shell().info("")
  end

  defp show_scip_status(project_dir) do
    Mix.shell().info("SCIP Bridge:")

    scip_cli = SCIPRegistry.scip_cli_available?()
    Mix.shell().info("  scip CLI: #{if scip_cli, do: "available", else: "not found"}")

    detected = SCIPRegistry.detect_languages(project_dir)

    if detected != [] do
      Mix.shell().info("  Detected languages:")

      Enum.each(detected, fn lang ->
        indexer_path = System.find_executable(lang.indexer)
        status = if indexer_path, do: "ready", else: "indexer not found"
        Mix.shell().info("    #{lang.language}: #{lang.indexer} (#{status})")
      end)
    else
      Mix.shell().info("  No SCIP-eligible languages detected")
    end
  end

  defp check_has_ragex(config_path) do
    case File.read(config_path) do
      {:ok, content} -> String.contains?(content, "ragex")
      _ -> false
    end
  end
end
