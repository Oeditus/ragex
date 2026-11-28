defmodule Ragex.Plugins.Prisma do
  @moduledoc """
  Plugin exposing Prisma's hybrid success/gradual type analysis as an MCP tool.

  Prisma is an Erlang application that analyzes **compiled beams** rather than
  source, so it proves things a source-level analyzer cannot: clauses that can
  never succeed, guards that can never match, `@spec` contracts the body
  violates, and private functions nothing calls. `Ragex.Analysis.Prisma` owns
  the subprocess bridge; this plugin is the MCP-facing surface.

  ## Why a plugin and not a built-in tool

  Prisma is *optional*: it only works for a project that depends on it and has
  been built with `mix prisma.build`. Modelling it as a language-scoped plugin
  means its tool is advertised only when the workspace actually contains Elixir
  or Erlang, and `available?/1` keeps it out of `tools/list` for projects where
  it could only fail. A tool that is already advertised stays callable by name
  regardless of scope -- scope governs discovery, never reachability.

  ## Relationship to `find_dead_code`

  `find_dead_code` infers reachability from a source call graph, so it cannot
  see through macros, protocol dispatch or dynamic `apply/3`. Prisma reads the
  compiler's own output and is therefore authoritative where the two disagree.
  They are complementary, not alternatives.

  ## Requirements

  The target project must depend on Prisma and must have been built once with
  `mix prisma.build` to produce the `.pplt` baseline. When either is missing,
  `analyze/2` returns `{:error, :unavailable}` and the tool reports an
  actionable message rather than raising.
  """

  @behaviour Ragex.Plugin
  @behaviour Ragex.Plugin.Language

  alias Ragex.Analysis.Prisma, as: Bridge
  alias Ragex.MCP.Handlers.Tools

  @impl true
  def info do
    %{
      id: :prisma,
      name: "Prisma Type Analysis",
      version: "0.1.0",
      description:
        "Runs Prisma's hybrid success/gradual type analysis over a compiled project, " <>
          "proving dead code and @spec violations that source-level analysis cannot detect.",
      category: :analyzer,
      # Prisma analyzes Erlang/Elixir beams, so the tool is only meaningful in a
      # workspace that actually contains one of those languages.
      language: [:elixir, :erlang],
      dependencies: [],
      priority: 30,
      capabilities: [:type_analysis, :dead_code, :gradual_typing, :success_typing]
    }
  end

  @impl true
  def languages, do: [:elixir, :erlang]

  @impl true
  def available?(path \\ "."), do: Bridge.available?(path)

  @impl true
  def tools, do: [tool_schema()]

  @impl true
  def language_tools(language) when is_atom(language) do
    if language in languages(), do: tools(), else: []
  end

  @impl true
  def execute("prisma_analyze", args), do: Tools.prisma_analyze_tool(args)

  def execute(tool_name, _args) do
    {:error, "Unknown tool '#{tool_name}' for the Prisma plugin"}
  end

  @doc "Returns the MCP tool schema for `prisma_analyze`."
  @spec tool_schema() :: Ragex.Plugin.tool_schema()
  def tool_schema do
    %{
      name: "prisma_analyze",
      description:
        "Run Prisma, a hybrid success/gradual type analyzer, against a COMPILED project. " <>
          "Proves dead code from beams (unreachable clauses, impossible guards, unused " <>
          "private functions) and reports @spec-vs-inferred type discrepancies that " <>
          "source-level analysis cannot detect. Requires the prisma package in the target " <>
          "project and a prior `mix prisma.build`. Complements find_dead_code, which infers " <>
          "from a source call graph.",
      inputSchema: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Project root containing mix.lock and _build",
            default: "."
          },
          mode: %{
            type: "string",
            description:
              "Analysis mode: hybrid (default), gradual (enforce @spec contracts), or " <>
                "discrepancy (success typing)",
            enum: ["hybrid", "gradual", "discrepancy"],
            default: "hybrid"
          },
          format: %{
            type: "string",
            description: "Output format",
            enum: ["summary", "detailed", "suggestions"],
            default: "summary"
          },
          include_oxbow: %{
            type: "boolean",
            description: "Include oxbow (dead/unreachable code) analysis",
            default: true
          }
        }
      },
      destruction_level: :none
    }
  end
end
