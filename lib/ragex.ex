defmodule Ragex do
  @moduledoc """
  Ragex - Hybrid Retrieval-Augmented Generation for multi-language codebases.

  An MCP (Model Context Protocol) server that analyzes codebases using compiler
  output and builds comprehensive knowledge graphs for natural language querying
  and editing.

  ## Architecture

  - **MCP Server**: JSON-RPC 2.0 server communicating via stdio
  - **Language Analyzers**: Pluggable parsers for different languages
  - **Knowledge Graph**: ETS-based storage for code entities and relationships
  - **Hybrid Retrieval**: Combines symbolic and semantic search (future)

  ## Usage as MCP Server

  Build and run the server:

      mix compile
      mix run --no-halt

  The server will listen for MCP messages on stdin and respond on stdout.
  """

  alias Ragex.Graph.Store

  @doc """
  Returns the version of Ragex.
  """
  def version do
    "0.1.0"
  end

  @doc """
  Returns statistics about the knowledge graph.
  """
  def stats do
    Store.stats()
  end
end
