defmodule Ragex.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  alias Ragex.AI.Config, as: AIConfig
  alias Ragex.Analyzers.Directory
  alias Ragex.Git.Backend, as: GitBackend

  require Logger

  @impl true
  def start(_type, _args) do
    # Validate AI config on startup (only if server is being started)
    if Application.get_env(:ragex, :start_server, true) do
      try do
        AIConfig.validate!()
        Logger.info("AI configuration validated successfully")
      rescue
        e ->
          Logger.warning("AI configuration validation failed: #{Exception.message(e)}")
          Logger.warning("AI features will be disabled")
      end
    end

    # When :skip_bumblebee is set (e.g. mix tasks while a server is already
    # running on the GPU), skip the heavyweight ML children to avoid
    # allocating GPU memory a second time.
    skip_bumblebee = Application.get_env(:ragex, :skip_bumblebee, false)

    # Base children that always start
    base_children =
      [
        # Graph store must start before MCP server
        Ragex.Graph.Store,
        # Embedding model for semantic search (heavy -- needs GPU)
        if(!skip_bumblebee, do: Ragex.Embeddings.Bumblebee),
        # Vector similarity search (depends on embeddings)
        if(!skip_bumblebee, do: Ragex.VectorStore),
        # File system watcher for auto-reindex
        Ragex.Watcher,
        # AI Provider Registry
        Ragex.AI.Provider.Registry,
        # AI response caching
        Ragex.AI.Cache,
        # AI Usage tracking and rate limiting
        Ragex.AI.Usage,
        # Agent conversation memory
        Ragex.Agent.Memory,
        # MCP tool telemetry tracking
        Ragex.MCP.Telemetry,
        # Git Enricher (background git metadata enrichment)
        Ragex.Git.Enricher,
        # Git RepoServer (NIF isolation for egit, only when egit is available)
        if(GitBackend.egit_available?(), do: Ragex.Git.RepoServer)
      ]
      |> Enum.reject(&is_nil/1)

    # MCP socket server starts unless :start_server is false
    socket_children =
      if Application.get_env(:ragex, :start_server, true) do
        [
          # MCP socket server for persistent connections (LunarVim, etc.)
          Ragex.MCP.SocketServer
        ]
      else
        []
      end

    # MCP stdio server starts only if explicitly enabled
    # Disabled by default in dev to avoid SIGTTIN when backgrounded
    stdio_children =
      if Application.get_env(
           :ragex,
           :start_stdio_server,
           Application.get_env(:ragex, :start_server, true)
         ) do
        [
          # MCP server handles stdio communication (for stdio-based clients)
          Ragex.MCP.Server
        ]
      else
        []
      end

    mcp_children = socket_children ++ stdio_children

    # REST API server (started when :start_api is true)
    api_children =
      if Application.get_env(:ragex, :start_api, false) do
        [Ragex.API.Server]
      else
        []
      end

    children = base_children ++ mcp_children ++ api_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ragex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def start_phase(:auto_analyze, :normal, _args) do
    auto_analyze_dirs = Application.get_env(:ragex, :auto_analyze_dirs, [])

    if auto_analyze_dirs != [] do
      Logger.info("Auto-analyzing #{length(auto_analyze_dirs)} configured directories...")

      Enum.each(auto_analyze_dirs, fn dir ->
        Logger.info("Analyzing directory: #{dir}")

        case Directory.analyze_directory(dir) do
          {:ok, result} ->
            Logger.info(
              "Successfully analyzed #{dir}: #{result.success} files (#{result.skipped} skipped, #{result.errors} errors)"
            )

          {:error, reason} ->
            Logger.warning("Failed to analyze #{dir}: #{inspect(reason)}")
        end
      end)

      Logger.info("Auto-analysis complete")
    end

    :ok
  end
end
