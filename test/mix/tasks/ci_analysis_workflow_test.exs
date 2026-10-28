defmodule Mix.Tasks.Ragex.CIAnalysisWorkflowTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  test "analysis jobs explicitly use the in-memory graph backend" do
    for {filename, job} <- [{"ragex-ci.yml", "analyze"}, {"ci.yml", "analysis"}] do
      workflow = read_workflow(filename)
      assert get_in(workflow, ["jobs", job, "env", "RAGEX_STORE_BACKEND"]) == "ets"
    end
  end

  test "only full-tree dogfooding tolerates failures while diff analysis remains blocking" do
    workflow = read_workflow("ragex-ci.yml")
    steps = get_in(workflow, ["jobs", "analyze", "steps"])
    dogfood = Enum.find(steps, &String.starts_with?(&1["name"] || "", "Dogfood"))
    diff = Enum.find(steps, &String.starts_with?(&1["name"] || "", "Run Ragex CI Audit"))

    assert dogfood["if"] == "always()"
    assert dogfood["continue-on-error"] == true
    refute Map.get(diff, "continue-on-error", false)
    assert dogfood["run"] =~ "--no-db --no-user"
    refute dogfood["run"] =~ "--ci"
    refute dogfood["run"] =~ "--strict"
  end

  defp read_workflow(name) do
    YamlElixir.read_from_file!(Path.join([@root, ".github", "workflows", name]))
  end
end
