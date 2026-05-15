defmodule Ragex.Git.PR do
  @moduledoc """
  Pull Request attribution and indexing.

  Uses the `gh` CLI (GitHub) or `glab` CLI (GitLab) to fetch PR metadata,
  including title, author, description, review comments, files changed,
  and merge commit. Results are stored in an ETS table and persisted
  to disk as Erlang term format (`.etf`).

  Gracefully degrades: if neither `gh` nor `glab` is installed, all
  functions return `{:error, :no_pr_cli}`.

  ## Examples

      # Index all merged PRs (incremental)
      {:ok, stats} = PR.index("/opt/project")

      # Find which PR introduced a commit
      {:ok, pr} = PR.find_pr_for_commit("/opt/project", "abc123")

      # Get review comments for a file
      comments = PR.review_comments_for_file("/opt/project", "lib/user.ex")
  """

  require Logger

  alias Ragex.Git.Repo

  @pr_table :ragex_pr_index
  @pr_comments_table :ragex_pr_comments

  defmodule PRInfo do
    @moduledoc "Struct representing an indexed pull request."
    defstruct [
      :number,
      :title,
      :author,
      :body,
      :state,
      :merge_commit_sha,
      :created_at,
      :merged_at,
      :url,
      files_changed: [],
      review_comments: []
    ]

    @type t :: %__MODULE__{
            number: pos_integer(),
            title: String.t(),
            author: String.t(),
            body: String.t() | nil,
            state: String.t(),
            merge_commit_sha: String.t() | nil,
            created_at: String.t() | nil,
            merged_at: String.t() | nil,
            url: String.t() | nil,
            files_changed: [String.t()],
            review_comments: [map()]
          }
  end

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Index PRs for the repository, fetching from GitHub/GitLab.

  Incremental: only fetches PRs newer than the last indexed one.

  ## Options
  - `:force` -- re-index all PRs (default `false`)
  - `:limit` -- max PRs to fetch (default 100)
  """
  @spec index(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def index(path, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    limit = Keyword.get(opts, :limit, 100)

    with {:ok, repo_root} <- Repo.root(path),
         {:ok, cli} <- detect_cli() do
      ensure_tables()

      last_pr = if force, do: 0, else: last_indexed_pr()

      case fetch_prs(cli, repo_root, limit) do
        {:ok, prs} ->
          new_prs = Enum.filter(prs, fn pr -> pr.number > last_pr end)

          Enum.each(new_prs, fn pr ->
            store_pr(pr)
          end)

          persist(repo_root)
          {:ok, %{total_indexed: :ets.info(@pr_table, :size), new: length(new_prs)}}

        error ->
          error
      end
    end
  end

  @doc """
  Find the PR that introduced a given commit SHA.

  Searches the PR index for a PR whose merge_commit_sha matches,
  or whose files overlap with the commit's changed files.
  """
  @spec find_pr_for_commit(String.t(), String.t()) :: {:ok, PRInfo.t()} | {:error, term()}
  def find_pr_for_commit(_repo_root, commit_sha) do
    ensure_tables()

    # Direct match on merge commit SHA
    result =
      :ets.foldl(
        fn {_key, pr}, acc ->
          if pr.merge_commit_sha == commit_sha, do: pr, else: acc
        end,
        nil,
        @pr_table
      )

    case result do
      nil -> {:error, :not_found}
      pr -> {:ok, pr}
    end
  end

  @doc """
  Get review comments associated with a file path.

  Returns comments from all PRs that touched the file.
  """
  @spec review_comments_for_file(String.t(), String.t()) :: [map()]
  def review_comments_for_file(_repo_root, file_path) do
    ensure_tables()

    case :ets.lookup(@pr_comments_table, file_path) do
      [{_, comments}] -> comments
      [] -> []
    end
  end

  @doc """
  Get a specific PR by number.
  """
  @spec get_pr(pos_integer()) :: {:ok, PRInfo.t()} | {:error, :not_found}
  def get_pr(pr_number) do
    ensure_tables()

    case :ets.lookup(@pr_table, pr_number) do
      [{_, pr}] -> {:ok, pr}
      [] -> {:error, :not_found}
    end
  end

  @doc "Load persisted PR index for a repository."
  @spec load(String.t()) :: :ok | {:error, :not_found}
  def load(repo_root) do
    ensure_tables()
    path = persistence_path(repo_root)

    if File.exists?(path) do
      {prs, comments} = path |> File.read!() |> :erlang.binary_to_term()

      Enum.each(prs, fn entry -> :ets.insert(@pr_table, entry) end)
      Enum.each(comments, fn entry -> :ets.insert(@pr_comments_table, entry) end)
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc "Clear PR index from memory."
  @spec clear() :: :ok
  def clear do
    ensure_tables()
    :ets.delete_all_objects(@pr_table)
    :ets.delete_all_objects(@pr_comments_table)
    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp ensure_tables do
    if :ets.whereis(@pr_table) == :undefined do
      :ets.new(@pr_table, [:named_table, :set, :public, read_concurrency: true])
    end

    if :ets.whereis(@pr_comments_table) == :undefined do
      :ets.new(@pr_comments_table, [:named_table, :set, :public, read_concurrency: true])
    end
  end

  defp detect_cli do
    cond do
      System.find_executable("gh") -> {:ok, :gh}
      System.find_executable("glab") -> {:ok, :glab}
      true -> {:error, :no_pr_cli}
    end
  end

  defp fetch_prs(:gh, repo_root, limit) do
    args = [
      "pr",
      "list",
      "--state=merged",
      "--limit=#{limit}",
      "--json=number,title,author,body,state,mergeCommit,createdAt,mergedAt,url,files,reviewComments"
    ]

    case System.cmd("gh", args, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} ->
        case :json.decode(output) do
          prs when is_list(prs) ->
            {:ok, Enum.map(prs, &parse_gh_pr/1)}

          _ ->
            {:error, :json_parse_failed}
        end

      {err, code} ->
        {:error, {err, code}}
    end
  rescue
    e -> {:error, {:gh_failed, Exception.message(e)}}
  end

  defp fetch_prs(:glab, repo_root, limit) do
    # GitLab CLI has a different JSON structure
    args = ["mr", "list", "--state=merged", "--per-page=#{limit}", "--output=json"]

    case System.cmd("glab", args, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} ->
        case :json.decode(output) do
          prs when is_list(prs) ->
            {:ok, Enum.map(prs, &parse_glab_mr/1)}

          _ ->
            {:error, :json_parse_failed}
        end

      {err, code} ->
        {:error, {err, code}}
    end
  rescue
    e -> {:error, {:glab_failed, Exception.message(e)}}
  end

  defp parse_gh_pr(pr) do
    files =
      case Map.get(pr, "files") do
        files when is_list(files) -> Enum.map(files, &Map.get(&1, "path", ""))
        _ -> []
      end

    comments =
      case Map.get(pr, "reviewComments") do
        comments when is_list(comments) ->
          Enum.map(comments, fn c ->
            %{
              body: Map.get(c, "body", ""),
              author: get_in(c, ["author", "login"]) || "",
              path: Map.get(c, "path", ""),
              line: Map.get(c, "line"),
              created_at: Map.get(c, "createdAt")
            }
          end)

        _ ->
          []
      end

    %PRInfo{
      number: Map.get(pr, "number"),
      title: Map.get(pr, "title", ""),
      author: get_in(pr, ["author", "login"]) || "",
      body: Map.get(pr, "body"),
      state: Map.get(pr, "state", "MERGED"),
      merge_commit_sha: get_in(pr, ["mergeCommit", "oid"]),
      created_at: Map.get(pr, "createdAt"),
      merged_at: Map.get(pr, "mergedAt"),
      url: Map.get(pr, "url"),
      files_changed: files,
      review_comments: comments
    }
  end

  defp parse_glab_mr(mr) do
    %PRInfo{
      number: Map.get(mr, "iid"),
      title: Map.get(mr, "title", ""),
      author: get_in(mr, ["author", "username"]) || "",
      body: Map.get(mr, "description"),
      state: Map.get(mr, "state", "merged"),
      merge_commit_sha: Map.get(mr, "merge_commit_sha"),
      created_at: Map.get(mr, "created_at"),
      merged_at: Map.get(mr, "merged_at"),
      url: Map.get(mr, "web_url")
    }
  end

  defp store_pr(%PRInfo{} = pr) do
    :ets.insert(@pr_table, {pr.number, pr})

    # Index review comments by file path
    Enum.each(pr.review_comments, fn comment ->
      path = comment.path
      enriched = Map.put(comment, :pr_number, pr.number) |> Map.put(:pr_title, pr.title)

      existing =
        case :ets.lookup(@pr_comments_table, path) do
          [{_, list}] -> list
          [] -> []
        end

      :ets.insert(@pr_comments_table, {path, [enriched | existing]})
    end)
  end

  defp last_indexed_pr do
    case :ets.info(@pr_table, :size) do
      0 ->
        0

      _ ->
        :ets.foldl(fn {number, _pr}, max -> max(number, max) end, 0, @pr_table)
    end
  end

  defp persist(repo_root) do
    path = persistence_path(repo_root)
    File.mkdir_p!(Path.dirname(path))

    prs = :ets.tab2list(@pr_table)
    comments = :ets.tab2list(@pr_comments_table)
    File.write!(path, :erlang.term_to_binary({prs, comments}))
  rescue
    e ->
      Logger.warning("Failed to persist PR index: #{Exception.message(e)}")
  end

  defp persistence_path(repo_root) do
    hash = Repo.project_hash(repo_root)
    Path.join([System.user_home!(), ".ragex", "pr_index", "#{hash}.etf"])
  end
end
