defmodule Ragex.Editor.ReportVisualizeTest do
  use ExUnit.Case, async: true

  alias Ragex.Editor.{Report, Visualize}

  describe "Report.generate/3" do
    setup do
      # Create sample report data
      report_data = %{
        operation: :rename_function,
        status: :success,
        stats: %{
          files_modified: 2,
          lines_added: 5,
          lines_removed: 3,
          functions_affected: 1
        },
        diffs: [
          %{
            file_path: "lib/test.ex",
            stats: %{added: 3, removed: 2, unchanged: 10},
            unified_diff: "@@ -1,3 +1,3 @@\n-old line\n+new line"
          }
        ],
        conflicts: [],
        warnings: ["Warning: high complexity"],
        timing: %{}
      }

      %{report_data: report_data}
    end

    test "generates markdown report", %{report_data: data} do
      {:ok, report} = Report.generate(data, :markdown)

      assert is_binary(report)
      assert String.contains?(report, "# Refactoring Report")
      assert String.contains?(report, "rename_function")
      assert String.contains?(report, "Files Modified: 2")
      assert String.contains?(report, "Lines Added: +5")
    end

    test "generates JSON report", %{report_data: data} do
      {:ok, report} = Report.generate(data, :json)

      assert is_binary(report)
      decoded = Jason.decode!(report)
      assert decoded["operation"] == "rename_function"
      assert decoded["status"] == "success"
      assert decoded["stats"]["files_modified"] == 2
    end

    test "generates HTML report", %{report_data: data} do
      {:ok, report} = Report.generate(data, :html)

      assert is_binary(report)
      assert String.contains?(report, "<!DOCTYPE html>")
      assert String.contains?(report, "rename_function")
      assert String.contains?(report, "<h1>")
    end

    test "respects include options" do
      data = %{
        operation: :test,
        status: :success,
        stats: %{files_modified: 0, lines_added: 0, lines_removed: 0, functions_affected: 0},
        diffs: [
          %{
            file_path: "test.ex",
            stats: %{added: 0, removed: 0, unchanged: 0},
            unified_diff: "diff"
          }
        ],
        conflicts: [],
        warnings: [],
        timing: %{}
      }

      {:ok, without_diffs} = Report.generate(data, :markdown, include_diffs: false)
      refute String.contains?(without_diffs, "## Diffs")

      {:ok, with_diffs} = Report.generate(data, :markdown, include_diffs: true)
      assert String.contains?(with_diffs, "## Diffs")
    end
  end

  describe "Report.create_report_data/3" do
    test "creates report data from refactor result and diffs" do
      refactor_result = %{
        operation: :rename_function,
        status: :success,
        warnings: ["Warning 1"]
      }

      diffs = [
        %{file_path: "test.ex", stats: %{added: 2, removed: 1, unchanged: 5}}
      ]

      conflicts = []

      report_data = Report.create_report_data(refactor_result, diffs, conflicts)

      assert report_data.operation == :rename_function
      assert report_data.status == :success
      assert report_data.stats.files_modified == 1
      assert report_data.stats.lines_added == 2
      assert report_data.stats.lines_removed == 1
    end
  end

  describe "Report.save_report/2" do
    test "saves report to file" do
      report = "# Test Report\nContent here"
      path = Path.join(System.tmp_dir!(), "test_report_#{:rand.uniform(10000)}.md")

      assert :ok = Report.save_report(report, path)
      assert File.exists?(path)
      assert File.read!(path) == report

      File.rm!(path)
    end
  end

  describe "Visualize.analyze_impact/3" do
    test "analyzes impact with no files" do
      {:ok, impact_data} = Visualize.analyze_impact([], 1, false)

      assert impact_data.affected_functions == []
      assert impact_data.affected_modules == []
      assert impact_data.impact_radius == 0
      assert impact_data.risk_score == 0.0
    end

    test "returns impact data structure" do
      # This test requires a populated graph, so we'll just verify the structure
      {:ok, impact_data} = Visualize.analyze_impact([], 1, true)

      assert Map.has_key?(impact_data, :affected_functions)
      assert Map.has_key?(impact_data, :affected_modules)
      assert Map.has_key?(impact_data, :impact_radius)
      assert Map.has_key?(impact_data, :risk_score)
      assert Map.has_key?(impact_data, :centrality_metrics)
    end
  end

  describe "Visualize.visualize_impact/3" do
    test "generates ASCII visualization" do
      {:ok, visualization} = Visualize.visualize_impact([], :ascii)

      assert is_binary(visualization)
      assert String.contains?(visualization, "=== Refactoring Impact Visualization ===")
      assert String.contains?(visualization, "Affected Functions:")
      assert String.contains?(visualization, "Impact Radius:")
      assert String.contains?(visualization, "Risk Score:")
    end

    test "generates Graphviz DOT format" do
      {:ok, dot} = Visualize.visualize_impact([], :graphviz)

      assert is_binary(dot)
      assert String.contains?(dot, "digraph RefactorImpact")
    end

    test "generates D3 JSON format" do
      {:ok, json} = Visualize.visualize_impact([], :d3_json)

      assert is_map(json)
      assert Map.has_key?(json, :nodes)
      assert Map.has_key?(json, :links)
      assert Map.has_key?(json, :impact_radius)
    end

    test "respects depth option" do
      {:ok, shallow} = Visualize.visualize_impact([], :ascii, depth: 0)
      {:ok, deep} = Visualize.visualize_impact([], :ascii, depth: 2)

      assert is_binary(shallow)
      assert is_binary(deep)
    end
  end

  describe "Visualize.visualize_diff/3" do
    test "generates ASCII diff visualization" do
      before = [{:function, :Foo, :bar, 1}]
      after_nodes = [{:function, :Foo, :baz, 1}]

      {:ok, diff} = Visualize.visualize_diff(before, after_nodes, :ascii)

      assert is_binary(diff)
      assert String.contains?(diff, "=== Refactoring Diff ===")
      assert String.contains?(diff, "Added:")
      assert String.contains?(diff, "Removed:")
    end

    test "generates Graphviz diff" do
      before = []
      after_nodes = [{:module, :NewModule}]

      {:ok, dot} = Visualize.visualize_diff(before, after_nodes, :graphviz)

      assert is_binary(dot)
      assert String.contains?(dot, "digraph RefactorDiff")
    end

    test "generates D3 JSON diff" do
      before = [{:function, :Foo, :old, 0}]
      after_nodes = [{:function, :Foo, :new, 0}]

      {:ok, json} = Visualize.visualize_diff(before, after_nodes, :d3_json)

      assert is_map(json)
      assert Map.has_key?(json, :nodes)
      assert is_list(json.nodes)
    end
  end
end
