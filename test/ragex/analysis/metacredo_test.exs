defmodule Ragex.Analysis.MetaCredoTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.MetaCredo

  # The bridge is exercised against real files in the repository rather than
  # fixture projects: MetaCredo is a hard dependency and its checks need a
  # parseable source file, which the repo itself supplies. A fixture would
  # duplicate the file-discovery and config-resolution paths the bridge is
  # specifically meant to delegate to MetaCredo.

  @sample_file "lib/ragex/plugin/registry.ex"

  describe "available?/1" do
    test "is always true -- MetaCredo is a hard dependency" do
      assert MetaCredo.available?()
      assert MetaCredo.available?(".")
    end
  end

  describe "run/1 argument validation" do
    test "rejects a non-map argument" do
      assert {:error, msg} = MetaCredo.run(%{"path" => 123})
      assert msg =~ "must be a string"
    end

    test "reports a missing path rather than an empty report" do
      assert {:error, msg} = MetaCredo.run(%{"path" => "/nonexistent/ragex"})
      assert msg =~ "no such file or directory"
    end
  end

  describe "run/1 over a single file" do
    test "returns counts, not findings, in summary format" do
      assert {:ok, report} = MetaCredo.run(%{"path" => @sample_file})

      assert report.status == "success"
      assert report.source == "metacredo"
      assert report.files_analyzed == 1
      assert report.checks_run > 0
      assert is_integer(report.total)

      # The summary is counts only -- shipping every finding defeats the point
      # of a summary format.
      refute Map.has_key?(report, :issues)
    end

    test "reports findings with repo-relative filenames in detailed format" do
      assert {:ok, report} = MetaCredo.run(%{"path" => @sample_file, "format" => "detailed"})

      assert report.total > 0

      for issue <- report.issues do
        # Absolute paths are silently dropped by GitHub Actions annotations and
        # are useless to an editor, so every filename must be repo-relative.
        refute String.starts_with?(issue.file, "/"), "expected relative path, got #{issue.file}"
        assert is_binary(issue.check)
        assert is_atom(issue.category)
      end
    end

    test "check names are shortened to their category-qualified form" do
      assert {:ok, report} = MetaCredo.run(%{"path" => @sample_file, "format" => "detailed"})

      for issue <- report.issues do
        refute String.starts_with?(issue.check, "MetaCredo."),
               "expected a short check name, got #{issue.check}"

        refute String.starts_with?(issue.check, "Check."),
               "expected the `Check.` prefix to be stripped, got #{issue.check}"
      end
    end

    test "min_confidence narrows the report" do
      assert {:ok, all} = MetaCredo.run(%{"path" => @sample_file})
      assert {:ok, high} = MetaCredo.run(%{"path" => @sample_file, "min_confidence" => "high"})

      assert high.total <= all.total
    end

    test "only/1 keeps a single category" do
      assert {:ok, report} =
               MetaCredo.run(%{
                 "path" => @sample_file,
                 "only" => "warning",
                 "format" => "detailed"
               })

      assert Map.keys(report.by_category) -- [:warning] == []
    end

    test "strict drops low-priority findings" do
      assert {:ok, loose} = MetaCredo.run(%{"path" => @sample_file})
      assert {:ok, strict} = MetaCredo.run(%{"path" => @sample_file, "strict" => true})

      assert strict.total <= loose.total
    end
  end

  describe "run/1 with an explicit file list" do
    test "analyses exactly the files given" do
      assert {:ok, report} =
               MetaCredo.run(%{"path" => ".", "files" => [@sample_file, "mix.exs"]})

      # mix.exs is excluded by `.metacredo.exs`, so only the source file is
      # analysed -- the config still applies to an explicit list.
      assert report.files_analyzed == 1
    end
  end

  describe "run/1 in diff mode" do
    test "reports partial: true when the diff resolves to no files" do
      # An empty diff must not read as a clean bill of health.
      assert {:ok, report} =
               MetaCredo.run(%{"path" => ".", "diff" => true, "base" => "HEAD", "head" => "HEAD"})

      assert report.partial
      assert report.diff.files_changed == 0
      assert report.total == 0
    end

    test "surfaces a bad ref instead of reporting zero findings" do
      assert {:error, msg} =
               MetaCredo.run(%{
                 "path" => ".",
                 "diff" => true,
                 "base" => "definitely-not-a-ref",
                 "head" => "HEAD"
               })

      assert msg =~ "could not resolve the git diff"
    end
  end

  describe "format output" do
    test "github format emits workflow commands" do
      assert {:ok, report} =
               MetaCredo.run(%{"path" => @sample_file, "format" => "github"})

      assert length(report.annotations) == report.total

      for annotation <- report.annotations do
        assert String.starts_with?(annotation, "::")
        assert annotation =~ "file="
      end
    end

    test "rejects an unknown format rather than silently defaulting" do
      assert {:error, msg} = MetaCredo.run(%{"path" => @sample_file, "format" => "yaml"})
      assert msg =~ "Unknown format"
    end
  end
end
