defmodule Ragex.URLAnalyzerTest do
  use ExUnit.Case, async: true

  alias Ragex.URLAnalyzer
  alias Ragex.URLAnalyzer.Classifier
  alias Ragex.URLAnalyzer.Report

  describe "Classifier.classify/1" do
    test "classifies GitHub repository URLs as :git_repo" do
      assert {:ok, :git_repo, meta} = Classifier.classify("https://github.com/elixir-lang/elixir")
      assert meta.host == "github.com"
      assert meta.path == "/elixir-lang/elixir"
    end

    test "classifies GitLab repository URLs as :git_repo" do
      assert {:ok, :git_repo, _} = Classifier.classify("https://gitlab.com/group/project.git")
    end

    test "classifies raw code links as :raw_code" do
      assert {:ok, :raw_code, _} =
               Classifier.classify("https://raw.githubusercontent.com/user/repo/main/lib/app.ex")

      assert {:ok, :raw_code, _} = Classifier.classify("https://example.com/script.py")
    end

    test "classifies API specification URLs as :api_spec" do
      assert {:ok, :api_spec, _} = Classifier.classify("https://example.com/openapi.json")
      assert {:ok, :api_spec, _} = Classifier.classify("https://example.com/swagger.yaml")
    end

    test "classifies generic web pages as :web_page" do
      assert {:ok, :web_page, _} = Classifier.classify("https://hexdocs.pm/elixir/Kernel.html")
    end

    test "returns error on invalid URL strings" do
      assert {:error, :invalid_url} = Classifier.classify("not a url")
    end
  end

  describe "Report.build_report/4" do
    test "builds machine-understandable JSON report map" do
      raw_analysis = %{
        metadata: %{title: "Test Page"},
        summary: %{overview: "A test overview"},
        headings: ["Heading 1", "Heading 2"],
        code_blocks: ["IO.puts(:hello)"],
        links: ["https://elixir-lang.org"]
      }

      assert {:ok, report} = Report.build_report("https://example.com", :web_page, raw_analysis)

      assert report.schema == "ragex.url_analysis.v1"
      assert report.url == "https://example.com"
      assert report.target_type == "web_page"
      assert is_binary(report.human_readable_report)
      assert report.metadata[:title] == "Test Page"
    end
  end

  describe "URLAnalyzer.analyze/2" do
    test "returns error gracefully for invalid URLs" do
      assert {:error, :invalid_url} = URLAnalyzer.analyze("invalid_url_without_scheme")
    end
  end
end
