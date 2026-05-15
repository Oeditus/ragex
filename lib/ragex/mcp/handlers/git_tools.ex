defmodule Ragex.MCP.Handlers.GitTools do
  @moduledoc """
  MCP tool definitions and handlers for git archaeology features.

  Provides 5 tools:
  - `git_blame` -- line or range blame with optional PR enrichment
  - `git_history` -- file or function history with filtering
  - `git_pr_info` -- PR details and review comments
  - `co_change_analysis` -- discover files that change together
  - `git_enrich` -- trigger knowledge graph enrichment with git data
  """

  alias Ragex.Git.Backend
  alias Ragex.Git.{Blame, CoChange, Enricher, Log, PR, Repo}

  # ── Tool definitions ─────────────────────────────────────────────────

  @doc "Returns the list of git tool definitions for tools/list."
  def tool_definitions do
    [
      %{
        name: "git_blame",
        description:
          "Show line-by-line git authorship for a file or line range. " <>
            "Returns who wrote each line, when, and in which commit.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "File path (absolute or relative to project root)"
            },
            start_line: %{
              type: "integer",
              description: "First line to blame (1-indexed, optional)"
            },
            end_line: %{
              type: "integer",
              description: "Last line to blame (optional, defaults to start_line)"
            },
            enrich_pr: %{
              type: "boolean",
              description: "Attach PR info to each blame entry if PR index is available",
              default: false
            }
          },
          required: ["path"]
        }
      },
      %{
        name: "git_history",
        description:
          "Show commit history for a file or track a specific function's evolution. " <>
            "Supports filtering by author and time range.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File path"},
            function_name: %{
              type: "string",
              description: "Function name to track (uses git log -L for evolution tracking)"
            },
            max_results: %{type: "integer", description: "Maximum commits to return", default: 20},
            since: %{type: "string", description: "Only show commits after this date (ISO-8601)"},
            author: %{type: "string", description: "Filter by author name substring"}
          },
          required: ["path"]
        }
      },
      %{
        name: "git_pr_info",
        description:
          "Get pull request details and review comments. " <>
            "Search by PR number, or by file path to find associated PRs and review comments.",
        inputSchema: %{
          type: "object",
          properties: %{
            pr_number: %{type: "integer", description: "PR number to look up"},
            path: %{type: "string", description: "File path to find review comments for"},
            index_first: %{
              type: "boolean",
              description: "If true, index PRs before querying (takes time)",
              default: false
            }
          }
        }
      },
      %{
        name: "co_change_analysis",
        description:
          "Discover files that frequently change together. " <>
            "Analyzes commit history to find co-change patterns. " <>
            "Useful for understanding coupling and predicting impact of changes.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File path to find co-change partners for"},
            analyze_first: %{
              type: "boolean",
              description: "Run co-change analysis before querying (slow but ensures fresh data)",
              default: false
            },
            max_commits: %{
              type: "integer",
              description: "Commits to analyze (if analyze_first)",
              default: 500
            },
            min_count: %{
              type: "integer",
              description: "Minimum co-change count to report",
              default: 2
            },
            limit: %{type: "integer", description: "Maximum results", default: 20}
          },
          required: ["path"]
        }
      },
      %{
        name: "git_enrich",
        description:
          "Enrich the knowledge graph with git metadata (authorship, dates, co-change edges). " <>
            "Run after analyzing a directory to add git context to the graph.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Project path to enrich"},
            analyze_cochange: %{
              type: "boolean",
              description: "Also run co-change analysis",
              default: true
            }
          },
          required: ["path"]
        }
      }
    ]
  end

  # ── Tool handlers ────────────────────────────────────────────────────

  @doc "Dispatch a git tool call. Returns `{:ok, result}` or `{:error, reason}`."
  def call_tool(name, arguments) do
    case name do
      "git_blame" -> handle_blame(arguments)
      "git_history" -> handle_history(arguments)
      "git_pr_info" -> handle_pr_info(arguments)
      "co_change_analysis" -> handle_co_change(arguments)
      "git_enrich" -> handle_enrich(arguments)
      _ -> {:error, "Unknown git tool: #{name}"}
    end
  end

  # ── git_blame ────────────────────────────────────────────────────────

  defp handle_blame(args) do
    path = Map.fetch!(args, "path")
    start_line = Map.get(args, "start_line")
    end_line = Map.get(args, "end_line")
    enrich_pr = Map.get(args, "enrich_pr", false)

    opts =
      [enrich_pr: enrich_pr] ++
        if(start_line, do: [start_line: start_line], else: []) ++
        if(end_line, do: [end_line: end_line], else: [])

    # Resolve: path may be absolute file path or relative
    work_dir = if File.dir?(path), do: path, else: Path.dirname(path)

    with {:ok, repo_root} <- Repo.root(work_dir),
         relative_path = Path.relative_to(path, repo_root),
         {:ok, entries} <- Blame.file(repo_root, relative_path, opts) do
      result =
        if start_line do
          # For line ranges, return detailed entries
          Enum.map(entries, &blame_entry_to_map/1)
        else
          # For full file, group by commit for compact output
          Blame.group_by_commit(entries)
        end

      {:ok, %{blame: result, file: relative_path, backend: to_string(Backend.active())}}
    end
  end

  # ── git_history ──────────────────────────────────────────────────────

  defp handle_history(args) do
    path = Map.fetch!(args, "path")
    function_name = Map.get(args, "function_name")
    max_results = Map.get(args, "max_results", 20)
    since = Map.get(args, "since")
    author = Map.get(args, "author")

    work_dir = if File.dir?(path), do: path, else: Path.dirname(path)

    with {:ok, repo_root} <- Repo.root(work_dir) do
      relative_path = Path.relative_to(path, repo_root)

      opts =
        [max_count: max_results] ++
          if(since, do: [since: since], else: []) ++
          if(author, do: [author: author], else: [])

      result =
        if function_name do
          Log.function_history(repo_root, function_name, relative_path, opts)
        else
          Log.file_history(repo_root, relative_path, opts)
        end

      case result do
        {:ok, commits} ->
          {:ok,
           %{
             commits: Enum.map(commits, &commit_to_map/1),
             file: relative_path,
             function: function_name,
             count: length(commits)
           }}

        error ->
          error
      end
    end
  end

  # ── git_pr_info ──────────────────────────────────────────────────────

  defp handle_pr_info(args) do
    pr_number = Map.get(args, "pr_number")
    path = Map.get(args, "path")
    index_first = Map.get(args, "index_first", false)

    cond do
      # Index PRs if requested
      index_first && path ->
        case PR.index(path) do
          {:ok, stats} ->
            {:ok, %{indexed: true, stats: stats}}

          error ->
            error
        end

      # Look up by PR number
      pr_number ->
        case PR.get_pr(pr_number) do
          {:ok, pr} -> {:ok, pr_to_map(pr)}
          error -> error
        end

      # Look up review comments by file path
      path ->
        with {:ok, repo_root} <- Repo.root(path) do
          relative_path = Path.relative_to(path, repo_root)
          comments = PR.review_comments_for_file(repo_root, relative_path)
          {:ok, %{file: relative_path, review_comments: comments, count: length(comments)}}
        end

      true ->
        {:error, "Provide either pr_number or path"}
    end
  end

  # ── co_change_analysis ───────────────────────────────────────────────

  defp handle_co_change(args) do
    path = Map.fetch!(args, "path")
    analyze_first = Map.get(args, "analyze_first", false)
    max_commits = Map.get(args, "max_commits", 500)
    min_count = Map.get(args, "min_count", 2)
    limit = Map.get(args, "limit", 20)

    with {:ok, repo_root} <- Repo.root(path) do
      if analyze_first do
        CoChange.analyze(repo_root, max_commits: max_commits)
      end

      relative_path = Path.relative_to(path, repo_root)
      co_files = CoChange.for_file(relative_path, min_count: min_count, limit: limit)

      {:ok,
       %{
         file: relative_path,
         co_changes: Enum.map(co_files, fn {f, count} -> %{file: f, count: count} end),
         total: length(co_files)
       }}
    end
  end

  # ── git_enrich ───────────────────────────────────────────────────────

  defp handle_enrich(args) do
    path = Map.fetch!(args, "path")
    analyze_cochange = Map.get(args, "analyze_cochange", true)

    with {:ok, repo_root} <- Repo.root(path) do
      # Run co-change analysis first if requested
      if analyze_cochange do
        CoChange.analyze(repo_root)
      end

      # Run enrichment synchronously for MCP tool response
      Enricher.enrich_sync(repo_root)
    end
  end

  # ── Formatting helpers ───────────────────────────────────────────────

  defp blame_entry_to_map(%Ragex.Git.BlameEntry{} = e) do
    %{
      line: e.line,
      sha: String.slice(e.sha, 0, 8),
      author: e.author,
      date: if(e.date, do: DateTime.to_iso8601(e.date)),
      summary: e.summary,
      content: e.content
    }
  end

  defp blame_entry_to_map(%{} = map), do: map

  defp commit_to_map(%Ragex.Git.Commit{} = c) do
    %{
      sha: c.short_sha || String.slice(c.sha, 0, 8),
      author: c.author,
      date: if(c.date, do: DateTime.to_iso8601(c.date)),
      summary: c.summary,
      files_changed: length(c.files_changed)
    }
  end

  defp pr_to_map(%Ragex.Git.PR.PRInfo{} = pr) do
    %{
      number: pr.number,
      title: pr.title,
      author: pr.author,
      state: pr.state,
      merged_at: pr.merged_at,
      url: pr.url,
      files_changed: length(pr.files_changed),
      review_comments: length(pr.review_comments)
    }
  end
end
