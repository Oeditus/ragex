defmodule Ragex.Plugins.MetaCredo do
  @moduledoc """
  Plugin exposing MetaCredo's cross-language static analysis as an MCP tool.

  MetaCredo is the engine behind `mix metacredo` and behind Ragex's own
  security / business-logic / smells analyzers (via
  `Ragex.Analysis.MetaCredoBridge`). This plugin exposes the *whole* pipeline —
  every enabled check from `.metacredo.exs`, the same file discovery, the same
  inline suppression — rather than the hand-picked subsets the analyzers run.

  ## Why a plugin and not a new built-in tool

  Diff-scoped review is a workflow, not a primitive: run the linter over the
  files a pull request touched and report only what that change introduced.
  Modelling it as a tool makes it reachable from any MCP client — an editor, a
  review agent, a CI runner — instead of being locked inside `mix ragex.ci`.

  ## Relationship to `mix ragex.ci`

  `mix ragex.ci` shells out to `mix metacredo --diff`. This tool calls
  `MetaCredo.Execution.run/1` in-process and resolves the diff with
  `Ragex.Git.Diff`, which is the same resolution the Mix task performs. The two
  agree on scope; the tool additionally returns structured findings instead of
  text on stdout.

  ## Availability

  MetaCredo is a hard Ragex dependency, so this plugin is always available.
  `available?/1` exists to satisfy `Ragex.Plugin.Language` and always returns
  `true`.
  """

  @behaviour Ragex.Plugin
  @behaviour Ragex.Plugin.Language

  alias Ragex.Analysis.MetaCredo, as: Bridge

  @impl true
  def info do
    %{
      id: :metacredo,
      name: "MetaCredo Static Analysis",
      version: "0.1.0",
      description:
        "Runs MetaCredo's cross-language checks (~70 security, warning, design, " <>
          "readability and refactoring checks) over a project or a git diff.",
      category: :analyzer,
      dependencies: [],
      priority: 30,
      capabilities: [:static_analysis, :diff_review, :cross_language_linting]
    }
  end

  # MetaCredo checks operate on MetaAST, so they apply to every language
  # Metastatic can parse -- not just Elixir. Declaring the full supported set
  # keeps the tool advertised for Python, Ruby, JavaScript and friends.
  @impl true
  def languages, do: Ragex.Languages.supported_languages()

  @impl true
  def available?(_path \\ "."), do: Bridge.available?()

  @impl true
  def tools, do: [tool_schema()]

  @impl true
  def language_tools(language) when is_atom(language) do
    if language in languages(), do: tools(), else: []
  end

  @impl true
  def execute("metacredo_analyze", args), do: Bridge.run(args)

  def execute(tool_name, _args) do
    {:error, "Unknown tool '#{tool_name}' for the MetaCredo plugin"}
  end

  @doc "Returns the MCP tool schema for `metacredo_analyze`."
  @spec tool_schema() :: Ragex.Plugin.tool_schema()
  def tool_schema do
    %{
      name: "metacredo_analyze",
      description:
        "Run MetaCredo's cross-language static analysis (~70 security, warning, design, " <>
          "readability, refactoring and observability checks) over a project or a git diff. " <>
          "Use `diff: true` to scope the run to the files a pull request touched -- the " <>
          "review workflow -- and `diff_lines: true` to report only findings on the lines " <>
          "the diff actually changed, while each file is still analysed whole. " <>
          "Honours `.metacredo.exs` (enabled/disabled checks, file patterns) and inline " <>
          "`# credo:disable-*` comments. Findings are a result, not an error: a report full " <>
          "of issues is a successful run. `partial: true` means the diff resolved to no " <>
          "files, so the empty result is not evidence of a clean change.",
      inputSchema: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description:
              "Project root or a single source file to analyze. Ignored when `files` or " <>
                "`diff` is given.",
            default: "."
          },
          diff: %{
            type: "boolean",
            description:
              "Scope the run to files changed between `base` and `head` (pull-request " <>
                "review mode)",
            default: false
          },
          base: %{
            type: "string",
            description: "Base git ref for diff mode",
            default: "origin/main"
          },
          head: %{
            type: "string",
            description: "Head git ref for diff mode",
            default: "HEAD"
          },
          diff_lines: %{
            type: "boolean",
            description:
              "Report only findings on lines the diff touched. Files are still analysed " <>
                "whole, because a check needs surrounding context.",
            default: false
          },
          files: %{
            type: "array",
            description: "Explicit list of files to analyze, overriding discovery",
            items: %{type: "string"}
          },
          strict: %{
            type: "boolean",
            description: "Only report findings at :normal priority or above",
            default: false
          },
          only: %{
            type: "string",
            description:
              "Comma-separated categories to keep (security, warning, design, " <>
                "readability, refactor, consistency, observability, performance)"
          },
          ignore: %{
            type: "string",
            description: "Comma-separated categories to skip"
          },
          min_confidence: %{
            type: "string",
            description:
              "Minimum confidence. `high` keeps only AST-structural findings and drops " <>
                "the name-substring heuristics that account for most false positives.",
            enum: ["high", "medium", "low"]
          },
          config: %{
            type: "string",
            description: "Path to a `.metacredo.exs` config file (default: project root)"
          },
          no_db: %{
            type: "boolean",
            description: "Skip DB-related checks",
            default: false
          },
          no_user: %{
            type: "boolean",
            description: "Skip user-input-related checks",
            default: false
          },
          format: %{
            type: "string",
            description:
              "Output verbosity: summary (counts), detailed (every finding), or github " <>
                "(GitHub Actions workflow commands)",
            enum: ["summary", "detailed", "github"],
            default: "summary"
          }
        },
        required: ["path"]
      },
      destruction_level: :none
    }
  end
end
