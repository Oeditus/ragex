defmodule Ragex.Test.GraphAnalysisHelper do
  @moduledoc """
  Shared test helper for storing analyzer output into `Ragex.Graph.Store`.

  Extracted because `test/editor/refactor_test.exs` and
  `test/editor/refactor_module_test.exs` each defined their own private,
  byte-for-byte identical `store_analysis/1` function (flagged by
  `Credo.Check.Design.DuplicatedCode`). This mirrors the analysis-storing
  logic in `Ragex.MCP.Handlers.Tools.store_analysis/1`, but lives here
  separately since production code should not depend on test support code.
  """

  alias Ragex.Graph.Store

  @doc "Stores modules, functions, and call edges from an analyzer result into the graph store."
  @spec store_analysis(%{modules: list(), functions: list(), calls: list()}) :: :ok
  def store_analysis(%{modules: modules, functions: functions, calls: calls}) do
    Enum.each(modules, fn module ->
      Store.add_node(:module, module.name, module)
    end)

    Enum.each(functions, fn func ->
      Store.add_node(:function, {func.module, func.name, func.arity}, func)

      Store.add_edge(
        {:module, func.module},
        {:function, func.module, func.name, func.arity},
        :defines
      )
    end)

    Enum.each(calls, fn call ->
      Store.add_edge(
        {:function, call.from_module, call.from_function, call.from_arity},
        {:function, call.to_module, call.to_function, call.to_arity},
        :calls
      )
    end)

    :ok
  end
end
