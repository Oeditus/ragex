defmodule Ragex.Plugins.Languages.Elixir do
  @moduledoc """
  Elixir language plugin.

  Contributes Elixir-specific tooling to Ragex. Unlike the generic plugins
  (`:graph_analytics`, `:code_quality`, ...), this one declares
  `language: :elixir`, so its tools are only advertised when the workspace
  actually contains Elixir sources.

  ## Tools

    * `propwise_analyze` -- property-based-testing candidates, backed by
      [PropWise](https://hexdocs.pm/propwise). Requires PropWise to be a
      dependency of the analysed project; otherwise the tool reports a clear
      `{:error, reason}` instead of being advertised as usable.

  ## Post-processing

  This plugin implements no `post_process/2` hook: the Elixir abstraction
  defects it used to compensate for (`@moduledoc` mistyped as a function call,
  raw AST leaking out of type expressions) are fixed in Metastatic itself, so
  there is nothing left to repair here.
  """

  @behaviour Ragex.Plugin
  @behaviour Ragex.Plugin.Language

  alias Ragex.Plugins.Languages.Elixir.Propwise

  @impl true
  def info do
    %{
      id: :elixir_language,
      name: "Elixir Language Support",
      version: "0.1.0",
      description: "Elixir-specific analysis: property-based-testing candidates via PropWise.",
      category: :analyzer,
      language: :elixir,
      dependencies: [],
      priority: 40,
      capabilities: [:property_testing]
    }
  end

  @impl true
  def languages, do: [:elixir]

  @impl true
  def available?(path) when is_binary(path), do: Propwise.available?(path)

  @impl true
  def tools, do: [Propwise.tool_schema()]

  @impl true
  def language_tools(:elixir), do: tools()
  def language_tools(_language), do: []

  @impl true
  def execute("propwise_analyze", args), do: Propwise.run(args)

  def execute(tool_name, _args) do
    {:error, "Unknown tool '#{tool_name}' for the Elixir language plugin"}
  end
end
