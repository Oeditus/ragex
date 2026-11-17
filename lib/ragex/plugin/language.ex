defmodule Ragex.Plugin.Language do
  @moduledoc """
  A `Ragex.Plugin` scoped to one or more source languages.

  Generic plugins (`:graph_analytics`, `:git_archaeology`, ...) are
  language-agnostic: their tools are advertised for every project. A language
  plugin instead declares which languages it serves, so its tools are only
  advertised when the workspace actually contains those languages, and it can
  additionally contribute language-specific behaviour that is not an MCP tool
  at all -- AST repairs, purity rules, idiom detectors.

  ## Relationship to `Ragex.Plugin`

  This is a *refinement*, not a replacement. A language plugin still implements
  `Ragex.Plugin` (`info/0`, `tools/0`, `execute/2`), and is registered through
  the same `Ragex.Plugin.Registry`. The extra callbacks below are optional
  hooks the registry and `Ragex.Plugin.LanguageRunner` look for.

  Declare the scope by adding a `:language` key to `info/0`:

      @impl true
      def info do
        %{
          id: :elixir_language,
          name: "Elixir Language Support",
          version: "0.1.0",
          description: "Elixir-specific analysis.",
          category: :analyzer,
          language: :elixir,
          priority: 40
        }
      end

  ## Availability

  An optional third-party tool (PropWise, Prisma, a SCIP indexer) may not be
  installed for the project being analysed. `available?/1` lets a plugin say so
  cheaply; the registry then leaves its tools out of `tools/list` rather than
  advertising something that can only fail. A tool that is already advertised
  stays callable by name regardless of scope -- scope governs discovery, never
  reachability.

  ## AST post-processing

  `post_process/2` runs after the Metastatic adapter has produced a document
  and before any analyzer consumes it. This is where a language plugin can
  repair abstraction defects without forking Metastatic. Implementations must
  return `{:ok, document}` or `{:error, reason}`; the runner logs and skips
  failures so a broken plugin cannot take down indexing.
  """

  alias Metastatic.Document

  @doc """
  The languages this plugin serves.

  Every entry must be a language known to `Ragex.Languages`; the registry
  refuses to register a plugin declaring an unknown language.
  """
  @callback languages() :: [atom()]

  @doc """
  Cheap probe for whether the plugin's backing tool is usable for `path`.

  Should not raise and should not perform expensive work -- it is called during
  tool-list assembly.
  """
  @callback available?(path :: String.t()) :: boolean()

  @doc """
  Tool schemas to advertise when `language` is active in the workspace.

  Defaults to `c:tools/0` when not implemented. Return `[]` to contribute no
  tools for a language.
  """
  @callback language_tools(language :: atom()) :: [Ragex.Plugin.tool_schema()]

  @doc """
  Post-process a parsed document for a language this plugin serves.
  """
  @callback post_process(Document.t(), keyword()) :: {:ok, Document.t()} | {:error, term()}

  @optional_callbacks [available?: 1, language_tools: 1, post_process: 2]
end
