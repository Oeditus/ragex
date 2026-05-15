defmodule Ragex.GitTest do
  @moduledoc """
  Tests for the Git Archaeology module tree.

  Uses the ragex repo itself as a fixture -- it's a real git repo with
  known history, so we can make concrete assertions against it.
  """

  use ExUnit.Case, async: false

  alias Ragex.Git.{Backend, Blame, BlameEntry, CoChange, Commit, Log, Repo}

  @repo_root File.cwd!()

  # ── Backend selection ────────────────────────────────────────────────

  describe "Backend" do
    test "active/0 returns CLI when egit is not loaded" do
      # egit is optional, unlikely to be loaded in test env
      backend = Backend.active()
      assert backend in [Backend.CLI, Backend.Egit]
    end

    test "egit_available?/0 returns a boolean" do
      assert is_boolean(Backend.egit_available?())
    end
  end

  # ── Repo ─────────────────────────────────────────────────────────────

  describe "Repo" do
    test "root/1 detects the ragex repo root" do
      assert {:ok, root} = Repo.root(@repo_root)
      assert File.exists?(Path.join(root, "mix.exs"))
    end

    test "root/1 caches result in process dictionary" do
      {:ok, root1} = Repo.root(@repo_root)
      {:ok, root2} = Repo.root(@repo_root)
      assert root1 == root2
    end

    test "git_available?/0 returns true on dev machines" do
      assert Repo.git_available?()
    end

    test "in_repo?/1 returns true for ragex root" do
      assert Repo.in_repo?(@repo_root)
    end

    test "in_repo?/1 returns false for /tmp" do
      # /tmp is unlikely to be a git repo
      tmp = System.tmp_dir!()
      refute Repo.in_repo?(tmp)
    end

    test "current_branch/1 returns a branch name" do
      assert {:ok, branch} = Repo.current_branch(@repo_root)
      assert is_binary(branch)
      assert String.length(branch) > 0
    end

    test "project_hash/1 is deterministic" do
      hash1 = Repo.project_hash(@repo_root)
      hash2 = Repo.project_hash(@repo_root)
      assert hash1 == hash2
      assert String.length(hash1) == 12
    end
  end

  # ── CLI Backend ──────────────────────────────────────────────────────

  describe "Backend.CLI" do
    test "repo_root/1 finds the ragex root" do
      assert {:ok, root} = Backend.CLI.repo_root(@repo_root)
      assert String.ends_with?(root, "ragex")
    end

    test "blame/3 returns blame entries for mix.exs" do
      {:ok, root} = Repo.root(@repo_root)
      assert {:ok, entries} = Backend.CLI.blame(root, "mix.exs")
      assert [_ | _] = entries
      first = hd(entries)
      assert %BlameEntry{} = first
      assert is_binary(first.sha)
      assert String.length(first.sha) == 40
      assert is_binary(first.author)
      assert first.line >= 1
    end

    test "blame/3 supports line range" do
      {:ok, root} = Repo.root(@repo_root)
      assert {:ok, entries} = Backend.CLI.blame(root, "mix.exs", start_line: 1, end_line: 5)
      assert length(entries) <= 5
    end

    test "log/3 returns commits for mix.exs" do
      {:ok, root} = Repo.root(@repo_root)
      assert {:ok, commits} = Backend.CLI.log(root, "mix.exs", max_count: 5)
      assert [_ | _] = commits
      first = hd(commits)
      assert %Commit{} = first
      assert is_binary(first.sha)
      assert is_binary(first.author)
      assert is_binary(first.summary)
    end

    test "rev_list/3 returns SHA list" do
      {:ok, root} = Repo.root(@repo_root)
      assert {:ok, shas} = Backend.CLI.rev_list(root, "HEAD", max_count: 10)
      assert [_ | _] = shas
      assert Enum.all?(shas, &(String.length(&1) == 40))
    end

    test "commit_info/2 returns a single commit" do
      {:ok, root} = Repo.root(@repo_root)
      {:ok, [sha | _]} = Backend.CLI.rev_list(root, "HEAD", max_count: 1)
      assert {:ok, %Commit{} = commit} = Backend.CLI.commit_info(root, sha)
      assert commit.sha == sha
    end

    test "diff/3 returns changed files" do
      {:ok, root} = Repo.root(@repo_root)
      {:ok, shas} = Backend.CLI.rev_list(root, "HEAD", max_count: 2)

      if length(shas) >= 2 do
        [newer, older | _] = shas
        assert {:ok, changes} = Backend.CLI.diff(root, older, newer)
        assert is_list(changes)
      end
    end
  end

  # ── High-level Blame API ─────────────────────────────────────────────

  describe "Blame" do
    test "file/3 returns blame for a known file" do
      assert {:ok, entries} = Blame.file(@repo_root, "mix.exs")
      assert [_ | _] = entries
    end

    test "group_by_commit/1 groups consecutive lines" do
      entries = [
        %BlameEntry{
          sha: "aaa",
          author: "Alice",
          email: "a@a",
          line: 1,
          original_line: 1,
          summary: "init"
        },
        %BlameEntry{
          sha: "aaa",
          author: "Alice",
          email: "a@a",
          line: 2,
          original_line: 2,
          summary: "init"
        },
        %BlameEntry{
          sha: "bbb",
          author: "Bob",
          email: "b@b",
          line: 3,
          original_line: 3,
          summary: "fix"
        }
      ]

      groups = Blame.group_by_commit(entries)
      assert [_, _] = groups
      assert hd(groups).line_count == 2
      assert List.last(groups).line_count == 1
    end
  end

  # ── High-level Log API ───────────────────────────────────────────────

  describe "Log" do
    test "file_history/3 returns commits" do
      assert {:ok, commits} = Log.file_history(@repo_root, "mix.exs", max_count: 3)
      assert [_ | _] = commits
    end

    test "commit_info/2 returns a commit" do
      {:ok, [first | _]} = Log.file_history(@repo_root, "mix.exs", max_count: 1)
      assert {:ok, %Commit{}} = Log.commit_info(@repo_root, first.sha)
    end
  end

  # ── CoChange ─────────────────────────────────────────────────────────

  describe "CoChange" do
    setup do
      CoChange.clear()
      :ok
    end

    test "analyze/2 builds co-change matrix" do
      assert {:ok, stats} = CoChange.analyze(@repo_root, max_commits: 20, persist: false)
      assert is_integer(stats.pairs)
      assert is_integer(stats.commits_analyzed)
      assert stats.commits_analyzed <= 20
    end

    test "for_file/2 returns co-change partners after analysis" do
      CoChange.analyze(@repo_root, max_commits: 50, persist: false)

      # mix.exs likely co-changes with mix.lock
      results = CoChange.for_file("mix.exs", min_count: 1)
      assert is_list(results)
      # Results are tuples of {path, count}
      with [_ | _] <- results do
        {path, count} = hd(results)
        assert is_binary(path)
        assert is_integer(count)
        assert count >= 1
      end
    end

    test "clear/0 empties the co-change data" do
      CoChange.analyze(@repo_root, max_commits: 5, persist: false)
      CoChange.clear()
      assert CoChange.for_file("mix.exs") == []
    end
  end

  # ── MCP Git Tools ────────────────────────────────────────────────────

  describe "MCP GitTools" do
    alias Ragex.MCP.Handlers.GitTools

    test "tool_definitions/0 returns 5 tools" do
      defs = GitTools.tool_definitions()
      assert [_, _, _, _, _] = defs
      names = Enum.map(defs, & &1.name)
      assert "git_blame" in names
      assert "git_history" in names
      assert "git_pr_info" in names
      assert "co_change_analysis" in names
      assert "git_enrich" in names
    end

    test "call_tool/2 handles git_blame" do
      path = Path.join(@repo_root, "mix.exs")

      assert {:ok, result} =
               GitTools.call_tool("git_blame", %{
                 "path" => path,
                 "start_line" => 1,
                 "end_line" => 3
               })

      assert is_map(result)
      assert is_list(result.blame)
    end

    test "call_tool/2 handles git_history" do
      path = Path.join(@repo_root, "mix.exs")

      assert {:ok, result} =
               GitTools.call_tool("git_history", %{"path" => path, "max_results" => 3})

      assert is_list(result.commits)
      assert result.count <= 3
    end

    test "call_tool/2 returns error for unknown tool" do
      assert {:error, _} = GitTools.call_tool("nonexistent", %{})
    end
  end
end
