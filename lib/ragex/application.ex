defmodule Ragex.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  alias Ragex.AI.Config, as: AIConfig
  alias Ragex.Analyzers.Directory

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

    # Base children that always start
    base_children = [
      # Graph store must start before MCP server
      Ragex.Graph.Store,
      # Embedding model for semantic search
      Ragex.Embeddings.Bumblebee,
      # Vector similarity search
      Ragex.VectorStore,
      # File system watcher for auto-reindex
      Ragex.Watcher,
      # AI Provider Registry
      Ragex.AI.Provider.Registry,
      # AI response caching
      Ragex.AI.Cache,
      # AI usage tracking and rate limiting
      Ragex.AI.Usage,
      # Agent conversation memory
      Ragex.Agent.Memory
    ]

    # MCP servers only start if :start_server is true (default)
    mcp_children =
      if Application.get_env(:ragex, :start_server, true) do
        [
          # MCP socket server for persistent connections
          Ragex.MCP.SocketServer,
          # MCP server handles stdio communication (for stdio-based clients)
          Ragex.MCP.Server
        ]
      else
        []
      end

    children = base_children ++ mcp_children

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
