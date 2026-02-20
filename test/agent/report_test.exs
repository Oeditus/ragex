defmodule Ragex.Agent.ReportTest do
  use ExUnit.Case, async: true

  alias Ragex.Agent.Report

  describe "system_prompt/0" do
    test "returns a string" do
      prompt = Report.system_prompt()

      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "contains key guidelines" do
      prompt = Report.system_prompt()

      assert prompt =~ "code reviewer"
      assert prompt =~ "severity"
      assert prompt =~ "recommendations"
    end
  end

  describe "format_issues_for_llm/1" do
    test "formats empty issues" do
      result = Report.format_issues_for_llm(%{})

      assert is_binary(result)
    end

    test "formats nil as no data" do
      result = Report.format_issues_for_llm(nil)

      assert result == "No issues data available."
    end

    test "formats dead code issues" do
      issues = %{
        dead_code: [
          %{file: "lib/foo.ex", name: "unused_func", line: 42, reason: "no callers"}
        ]
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "Dead Code"
      assert result =~ "unused_func"
      assert result =~ "lib/foo.ex:42"
    end

    test "formats duplicate issues" do
      issues = %{
        duplicates: [
          %{file1: "lib/a.ex", file2: "lib/b.ex", similarity: 0.95, lines: 50}
        ]
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "Duplicate"
      assert result =~ "95%"
      assert result =~ "lib/a.ex"
      assert result =~ "lib/b.ex"
    end

    test "formats security issues" do
      issues = %{
        security: [
          %{
            severity: "high",
            type: "SQL Injection",
            file: "lib/db.ex",
            line: 10,
            description: "Unsafe query"
          }
        ]
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "Security"
      assert result =~ "[HIGH]"
      assert result =~ "SQL Injection"
    end

    test "formats code smells" do
      issues = %{
        smells: [
          %{type: "long_function", file: "lib/big.ex", line: 1, message: "Function too long"}
        ]
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "Code Smell"
      assert result =~ "long_function"
    end

    test "formats complexity issues" do
      issues = %{
        complexity: [
          %{
            function: "complex_func",
            file: "lib/complex.ex",
            line: 20,
            cyclomatic: 25,
            cognitive: 30
          }
        ]
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "Complexity"
      assert result =~ "complex_func"
      assert result =~ "25"
    end

    test "formats circular dependencies" do
      issues = %{
        circular_deps: [
          %{cycle: ["ModuleA", "ModuleB", "ModuleA"]}
        ]
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "Circular"
      assert result =~ "ModuleA"
      assert result =~ "ModuleB"
    end

    test "formats refactoring suggestions" do
      issues = %{
        suggestions: [
          %{
            type: "extract_function",
            priority: "high",
            target: "MyModule.big_func/3",
            reason: "Too complex"
          }
        ]
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "Refactoring"
      assert result =~ "[HIGH]"
      assert result =~ "extract_function"
    end

    test "truncates long lists" do
      # Create 60 items
      dead_code =
        for i <- 1..60 do
          %{file: "lib/file#{i}.ex", name: "func#{i}", line: i, reason: "unused"}
        end

      issues = %{dead_code: dead_code}
      result = Report.format_issues_for_llm(issues)

      # Should show truncation notice
      assert result =~ "... and"
      assert result =~ "more items"
    end

    test "handles missing fields gracefully" do
      issues = %{
        dead_code: [%{}],
        security: [%{type: "issue"}],
        complexity: [%{function: "test"}]
      }

      # Should not crash
      result = Report.format_issues_for_llm(issues)
      assert is_binary(result)
    end

    test "handles items wrapped in map" do
      issues = %{
        dead_code: %{
          items: [
            %{file: "lib/foo.ex", name: "unused_func", line: 42}
          ]
        }
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "Dead Code"
      assert result =~ "unused_func"
    end
  end

  describe "generate_basic_report/1" do
    test "generates report for issues" do
      issues = %{
        dead_code: [%{file: "lib/foo.ex", name: "unused", line: 1}],
        security: [],
        complexity: []
      }

      report = Report.generate_basic_report(issues)

      assert is_binary(report)
      assert report =~ "Code Analysis Report"
      assert report =~ "Summary"
      assert report =~ "Recommendations"
    end

    test "generates report for empty issues" do
      report = Report.generate_basic_report(%{})

      assert is_binary(report)
      assert report =~ "Code Analysis Report"
    end

    test "generates report for nil" do
      report = Report.generate_basic_report(nil)

      assert is_binary(report)
      assert report =~ "No issues were found"
    end

    test "includes timestamp" do
      report = Report.generate_basic_report(%{})

      # Should contain date
      assert report =~ "Generated:"
    end

    test "includes summary table" do
      issues = %{
        dead_code: [%{}, %{}],
        security: [%{}],
        duplicates: []
      }

      report = Report.generate_basic_report(issues)

      assert report =~ "Dead Code"
      assert report =~ "Security"
      assert report =~ "Total Issues"
    end

    test "includes automated note" do
      report = Report.generate_basic_report(%{})

      assert report =~ "automated report"
    end
  end

  describe "format helpers" do
    test "formats severity levels correctly" do
      issues = %{
        security: [
          %{severity: "critical", type: "vuln", file: "f", line: 1},
          %{severity: :high, type: "vuln", file: "f", line: 2},
          %{severity: "medium", type: "vuln", file: "f", line: 3},
          %{severity: "low", type: "vuln", file: "f", line: 4}
        ]
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "[CRITICAL]"
      assert result =~ "[HIGH]"
      assert result =~ "[MEDIUM]"
      assert result =~ "[LOW]"
    end

    test "formats priority levels correctly" do
      issues = %{
        suggestions: [
          %{type: "refactor", priority: "high", target: "t1"},
          %{type: "refactor", priority: :low, target: "t2"},
          %{type: "refactor", priority: 1, target: "t3"},
          %{type: "refactor", priority: 5, target: "t4"}
        ]
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "[HIGH]"
      assert result =~ "[LOW]"
    end

    test "handles list circular deps" do
      issues = %{
        circular_deps: [
          ["A", "B", "C", "A"]
        ]
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "A -> B -> C -> A"
    end

    test "handles string keys in maps" do
      issues = %{
        dead_code: [
          %{"file" => "lib/foo.ex", "name" => "func", "line" => 10}
        ]
      }

      result = Report.format_issues_for_llm(issues)

      assert result =~ "lib/foo.ex"
      assert result =~ "func"
    end
  end
end
