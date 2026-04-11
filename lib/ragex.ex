defmodule Ragex do
  @moduledoc """
  Ragex - Hybrid Retrieval-Augmented Generation for multi-language codebases.

  An MCP (Model Context Protocol) server that analyzes codebases using compiler
  output and language-native tools to build comprehensive knowledge graphs for
  natural language querying, static analysis, and safe code editing.

  ## Architecture

  - **MCP Server**: JSON-RPC 2.0 server over stdio and socket (50+ tools)
  - **Language Analyzers**: Pluggable parsers for Elixir, Erlang, Python, Ruby, JS/TS
  - **Knowledge Graph**: ETS-based storage for code entities and relationships
  - **Hybrid Retrieval**: Reciprocal Rank Fusion of symbolic + semantic search
  - **Bumblebee Embeddings**: Local ML model for semantic code search
  - **Code Analysis**: Quality, security, business logic, duplication, dead code
  - **Code Editing**: Atomic file edits, semantic refactoring, multi-file transactions
  - **AI Agent**: ReAct-loop agent using Ragex MCP tools for RAG (chat, audit)

  ## Usage as MCP Server

  Build and run the server:

      mix compile
      mix run --no-halt

  The server listens for MCP messages on stdin and responds on stdout.
  A socket server also starts on a configurable port for persistent connections.

  ## Interactive CLI Tasks

      # AI-powered codebase Q&A via agent with Ragex MCP tools
      mix ragex.chat

      # AI-powered static analysis + audit report
      mix ragex.audit

      # Comprehensive static analysis
      mix ragex.analyze
  """

  alias Ragex.Graph.Store

  @doc """
  Returns statistics about the knowledge graph.
  """
  def stats do
    Store.stats()
  end
end
