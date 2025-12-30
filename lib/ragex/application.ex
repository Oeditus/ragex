defmodule Ragex.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Graph store must start before MCP server
      Ragex.Graph.Store,
      # Embedding model for semantic search
      Ragex.Embeddings.Bumblebee,
      # Vector similarity search
      Ragex.VectorStore,
      # File system watcher for auto-reindex
      Ragex.Watcher,
      # MCP server handles stdio communication
      Ragex.MCP.Server
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ragex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
