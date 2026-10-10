defmodule Ragex.Analysis.LocationEnricherTest do
  # The knowledge graph store is a global singleton and several async tests
  # clear it in their own setup, so this suite must run serially to keep the
  # nodes it registers visible for the duration of each test.
  use ExUnit.Case, async: false

  alias Ragex.Analysis.LocationEnricher
  alias Ragex.Graph.Store

  setup do
    Store.clear()
    Store.sync()
    LocationEnricher.clear_cache()
    :ok
  end

  describe "enrich_issue/2 with non-tuple function node IDs" do
    test "correctly enriches location when function node has string id (DLLB backend shape)" do
      file = "/opt/Proyectos/Oeditus/dllb_ex/lib/dllb/connection.ex"

      # Node shape produced by DLLB backend
      dllb_node = %{
        id: "batch_transaction",
        data: %{
          arity: 3,
          line: 102,
          module: "Elixir.Dllb.Connection",
          name: "batch_transaction",
          file: file,
          kind: "function"
        }
      }

      Store.add_node(:function, dllb_node.id, dllb_node.data)
      Store.sync()

      issue = %{
        file: file,
        line: 104,
        context: %{function_name: "batch_transaction"}
      }

      enriched = LocationEnricher.enrich_issue(issue, file)

      assert enriched.file == file
      assert enriched.line == 104
      assert enriched.location.arity == 3
    end
  end
end
