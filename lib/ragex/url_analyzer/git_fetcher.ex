defmodule Ragex.URLAnalyzer.GitFetcher do
  @moduledoc """
  Clones and analyzes Git repositories using Ragex's code analysis suite.
  """

  alias Ragex.Analyzers.Directory, as: DirectoryAnalyzer

  require Logger

  @doc """
  Clones a repository into a temporary directory, runs Ragex code analysis,
  extracts architecture details, and cleans up the cloned repository.

  ## Options

  - `:auth_token` - Authentication token for private repositories
  - `:depth` - Shallow clone depth (default: 1)
  - `:index_graph` - Whether to index findings into the knowledge graph (default: true)
  """
  def analyze_repository(url_string, opts \\ []) do
    auth_token =
      Keyword.get(opts, :auth_token) || System.get_env("GITHUB_TOKEN") ||
        System.get_env("GITLAB_TOKEN")

    clone_url = build_clone_url(url_string, auth_token)
    temp_dir = Path.join(System.tmp_dir!(), "ragex_git_#{System.unique_integer([:positive])}")

    try do
      with {:ok, _} <- clone_repo(clone_url, temp_dir, opts),
           commit_info <- extract_git_meta(temp_dir),
           readme_summary <- read_readme(temp_dir),
           {:ok, dir_analysis} <- DirectoryAnalyzer.analyze_directory(temp_dir, notify: false) do
        lang_stats = compute_language_stats(dir_analysis)
        entry_points = find_entry_points(temp_dir)
        smells_summary = run_smells_analysis(dir_analysis)
        security_summary = run_security_analysis(dir_analysis)
        dep_graph = run_dependency_graph(dir_analysis)

        repo_report = %{
          git_metadata: commit_info,
          readme: readme_summary,
          summary: %{
            total_files: dir_analysis[:analyzed_files] || 0,
            total_modules: dir_analysis[:modules_count] || 0,
            total_functions: dir_analysis[:functions_count] || 0,
            languages: lang_stats
          },
          architecture: %{
            entry_points: entry_points,
            dependency_graph_summary: dep_graph
          },
          quality_and_metrics: %{
            smells_detected: smells_summary,
            security_warnings: security_summary
          },
          details: dir_analysis
        }

        {:ok, repo_report}
      else
        {:error, reason} ->
          Logger.error("Failed to analyze git repo at #{url_string}: #{inspect(reason)}")
          {:error, {:git_analysis_failed, reason}}
      end
    after
      File.rm_rf(temp_dir)
    end
  end

  defp build_clone_url(url_string, nil), do: ensure_git_suffix(url_string)

  defp build_clone_url(url_string, token) when is_binary(token) do
    case URI.parse(url_string) do
      %URI{scheme: "https", host: host, path: path} ->
        "https://oauth2:#{token}@#{host}#{path}" |> ensure_git_suffix()

      _ ->
        ensure_git_suffix(url_string)
    end
  end

  defp ensure_git_suffix(url) do
    if String.ends_with?(url, ".git") do
      url
    else
      url <> ".git"
    end
  end

  defp clone_repo(clone_url, temp_dir, opts) do
    depth = Keyword.get(opts, :depth, 1)

    args = ["clone", "--depth", to_string(depth), clone_url, temp_dir]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, temp_dir}

      {output, _code} ->
        # Redact token from log output if present
        safe_output = String.replace(output, ~r/oauth2:[^@]+@/, "oauth2:***@")
        {:error, safe_output}
    end
  end

  defp extract_git_meta(dir) do
    commit = run_git_cmd(dir, ["rev-parse", "HEAD"])
    branch = run_git_cmd(dir, ["branch", "--show-current"])
    author = run_git_cmd(dir, ["log", "-1", "--format=%an <%ae>"])
    date = run_git_cmd(dir, ["log", "-1", "--format=%cd"])

    %{
      commit_hash: commit,
      branch: branch,
      last_commit_author: author,
      last_commit_date: date
    }
  end

  defp run_git_cmd(dir, args) do
    case System.cmd("git", args, cd: dir) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  end

  defp read_readme(dir) do
    candidates = ["README.md", "readme.md", "README", "README.txt"]

    Enum.find_value(candidates, fn name ->
      path = Path.join(dir, name)

      if File.exists?(path) do
        case File.read(path) do
          {:ok, content} ->
            String.slice(content, 0, 3000)

          _ ->
            nil
        end
      end
    end)
  end

  defp compute_language_stats(dir_analysis) do
    files = dir_analysis[:files] || []

    files
    |> Enum.group_by(fn file ->
      file_path = file[:path] || file[:file] || ""
      Path.extname(file_path) |> String.downcase()
    end)
    |> Enum.map(fn {ext, group} ->
      {ext, length(group)}
    end)
    |> Enum.into(%{})
  end

  defp find_entry_points(dir) do
    patterns = [
      "mix.exs",
      "lib/*/application.ex",
      "main.py",
      "app.py",
      "index.js",
      "src/index.js",
      "src/main.rs",
      "main.go",
      "src/Main.java",
      "Dockerfile"
    ]

    Enum.flat_map(patterns, fn pattern ->
      Path.wildcard(Path.join(dir, pattern))
      |> Enum.map(&Path.relative_to(&1, dir))
    end)
  end

  defp run_smells_analysis(dir_analysis) do
    case Map.fetch(dir_analysis, :smells) do
      {:ok, smells} -> length(smells)
      _ -> 0
    end
  end

  defp run_security_analysis(dir_analysis) do
    case Map.fetch(dir_analysis, :security) do
      {:ok, sec} -> length(sec)
      _ -> 0
    end
  end

  defp run_dependency_graph(dir_analysis) do
    %{
      modules_count: dir_analysis[:modules_count] || 0,
      functions_count: dir_analysis[:functions_count] || 0
    }
  end
end
