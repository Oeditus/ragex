defmodule Ragex.Analysis.MetaCredo do
  @moduledoc """
  Bridge to [MetaCredo](https://hexdocs.pm/metacredo), the cross-language
  static-analysis engine behind `mix metacredo`.

  MetaCredo runs ~70 checks — security, warnings, design, readability,
  refactoring, consistency, observability — over MetaAST, so the same check
  applies to Elixir, Erlang, Python, Ruby, JavaScript and the rest of the
  Metastatic language set. It is the engine Ragex's own `security`,
  `business_logic` and `smells` analyzers already borrow from through
  `Ragex.Analysis.MetaCredoBridge`.

  ## Why this exists

  `MetaCredoBridge` runs a *hand-picked* list of checks on a single
  already-parsed file. That is the right shape for an analyzer that wants
  security findings shaped like Ragex's own. It is the wrong shape for
  "run the linter the way CI does", which is what a review workflow needs:
  the full enabled-check set from `.metacredo.exs`, the same file discovery,
  the same inline `# credo:disable-*` suppression, and diff scoping.

  This module therefore calls MetaCredo's own pipeline
  (`MetaCredo.Execution.run/1`) and normalizes the resulting
  `MetaCredo.Issue` structs into plain maps.

  ## In-process, not a subprocess

  Unlike `Ragex.Analysis.Prisma` — which must shell out because its Mix task
  calls `erlang:halt/1` — `MetaCredo.Execution.run/1` is a pure library call
  that returns a report map. It also happens to be a Ragex dependency already,
  so there is nothing to probe for: `available?/1` is always `true` and exists
  only to satisfy the plugin contract.

  ## Diff mode

  `--diff` support is reimplemented here rather than delegated to
  `mix metacredo --diff`, because the diff has to be resolved *before*
  `Execution.run/1` is called: `Execution` takes an explicit file list, and
  resolving it inside the Mix task would mean spawning a subprocess to get a
  list we can compute directly with `Ragex.Git.Diff`.

  Two MetaCredo behaviours are deliberately preserved:

    * `lift_test_exclusion: false` — a diff-derived file list is machine
      generated, not a deliberate user opt-in, so the default `test/`
      exclusion stays in force, exactly as `mix metacredo --diff` does.
    * `diff_lines: true` narrows *reporting* to the lines the diff touched
      while still analysing each changed file whole, because a check needs
      surrounding context to judge a line.
  """

  alias Ragex.Git.Diff
  alias Ragex.Git.Repo

  @type finding :: %{
          check: String.t(),
          category: atom(),
          severity: atom(),
          priority: atom() | integer(),
          confidence: atom(),
          message: String.t(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          trigger: String.t() | nil
        }

  @type report :: %{
          status: String.t(),
          source: String.t(),
          total: non_neg_integer(),
          by_category: map(),
          by_severity: map(),
          by_check: map(),
          files_analyzed: non_neg_integer(),
          checks_run: non_neg_integer(),
          timing_ms: non_neg_integer() | nil,
          partial: boolean(),
          diff: map() | nil,
          issues: [finding()]
        }

  @default_format "summary"

  @doc """
  Returns whether MetaCredo is usable.

  Always `true`: MetaCredo is a hard Ragex dependency, so there is no probe to
  make. The function exists because `Ragex.Plugin.Language` requires it.
  """
  @spec available?(String.t()) :: boolean()
  def available?(_path \\ "."), do: Code.ensure_loaded?(MetaCredo.Execution)

  @doc """
  Runs MetaCredo over a project or an explicit file list and normalizes the
  issues it reports.

  ## Options (string keys, as received from an MCP tool call)

    * `"path"` — project root or a single file (default `"."`)
    * `"diff"` — scope to files changed between `"base"` and `"head"`
    * `"base"` / `"head"` — git refs for diff mode
    * `"diff_lines"` — report only findings on lines the diff touched
    * `"files"` — explicit list of paths, overriding discovery
    * `"strict"` — drop findings below `:normal` priority
    * `"only"` / `"ignore"` — category allow/deny lists
    * `"min_confidence"` — `"high"`, `"medium"` or `"low"`
    * `"config"` — path to a `.metacredo.exs`
    * `"no_db"` / `"no_user"` — umbrella switches for DB / user-input checks
    * `"format"` — `"summary"`, `"detailed"` or `"github"`

  ## Return values

    * `{:ok, report}` — the run completed. Findings are a result, not an
      error: a report full of issues is a successful analysis.
    * `{:error, reason}` — the path does not exist, diff resolution failed,
      or an option could not be parsed.
  """
  @spec run(map()) :: {:ok, report() | map()} | {:error, term()}
  def run(params) when is_map(params) do
    path = Map.get(params, "path", ".")
    format = Map.get(params, "format", @default_format)

    with {:ok, root} <- resolve_root(path),
         {:ok, scope} <- resolve_scope(root, params) do
      report =
        root
        |> execution_opts(scope, params)
        |> MetaCredo.Execution.run()

      format(report, format, scope)
    end
  end

  def run(_params), do: {:error, "metacredo_analyze requires a map of arguments"}

  # ----- Scope resolution ----------------------------------------------------

  # `path` may name a project directory or a single file. Both are normalized
  # to an absolute project root plus an optional single-file target, so the
  # rest of the pipeline only ever deals with a root.
  defp resolve_root(path) when is_binary(path) do
    expanded = Path.expand(path)

    cond do
      File.dir?(expanded) ->
        {:ok, expanded}

      File.regular?(expanded) ->
        {:ok, Path.dirname(expanded)}

      true ->
        {:error,
         "metacredo_analyze: no such file or directory: #{expanded}. " <>
           "Point \"path\" at a project root or a source file."}
    end
  end

  defp resolve_root(other),
    do: {:error, "metacredo_analyze: \"path\" must be a string, got: #{inspect(other)}"}

  # The scope is whatever `Execution.run/1` needs to know about *which* files
  # to analyse: an explicit list, a single file, or nothing at all (let the
  # config's `included` patterns decide).
  defp resolve_scope(root, params) do
    cond do
      is_list(params["files"]) ->
        explicit_scope(root, params["files"])

      Map.get(params, "diff") == true ->
        diff_scope(root, params)

      true ->
        case single_file_scope(root, params["path"]) do
          nil -> {:ok, %{kind: :config}}
          {_file, scope} -> {:ok, scope}
        end
    end
  end

  # Reported filenames are repo-relative whenever the root sits inside a git
  # repository, matching `mix metacredo` -- an absolute path in a GitHub
  # annotation is silently dropped.
  defp explicit_scope(root, files) do
    strip_prefix =
      case Repo.root(root) do
        {:ok, repo_root} -> repo_root
        {:error, _} -> nil
      end

    {:ok,
     %{
       kind: :explicit,
       files: Enum.map(files, &Path.expand(&1, root)),
       strip_prefix: strip_prefix
     }}
  end

  defp single_file_scope(root, path) when is_binary(path) do
    expanded = Path.expand(path)

    if File.regular?(expanded) do
      case explicit_scope(root, [expanded]) do
        {:ok, %{files: [file]} = scope} -> {file, scope}
      end
    end
  end

  defp single_file_scope(_root, _path), do: nil

  # Mirrors `mix metacredo --diff`: resolve changed files from git, hand
  # `Execution` absolute paths, and rewrite the reported filenames back to
  # repo-relative afterwards (done in `normalize_issue/1` via `:strip_prefix`).
  defp diff_scope(root, params) do
    base = Map.get(params, "base", "origin/main")
    head = Map.get(params, "head", "HEAD")
    diff_lines? = Map.get(params, "diff_lines") == true

    diff_opts = [
      base: base,
      head: head,
      extensions: MetaCredo.Sources.supported_extensions()
    ]

    with {:ok, repo_root} <- Repo.root(root),
         {:ok, files} <- Diff.changed_files(repo_root, diff_opts),
         {:ok, changed_lines} <- maybe_changed_lines(diff_lines?, repo_root, diff_opts) do
      {:ok,
       %{
         kind: :diff,
         files: Enum.map(files, &Path.join(repo_root, &1)),
         changed_lines: changed_lines,
         strip_prefix: repo_root,
         diff: %{base: base, head: head, files_changed: length(files)}
       }}
    else
      {:error, reason} ->
        {:error,
         "metacredo_analyze: could not resolve the git diff between #{base} and #{head}: " <>
           "#{format_reason(reason)}"}
    end
  end

  defp maybe_changed_lines(false, _repo_root, _diff_opts), do: {:ok, nil}

  defp maybe_changed_lines(true, repo_root, diff_opts) do
    case MetaCredo.Git.changed_lines(repo_root, diff_opts) do
      {:ok, lines} -> {:ok, lines}
      {:error, reason} -> {:error, reason}
    end
  end

  # ----- Execution options ---------------------------------------------------

  defp execution_opts(root, scope, params) do
    [
      config_file: params["config"],
      strict: params["strict"] == true,
      only: parse_categories(params["only"]),
      ignore: parse_categories(params["ignore"]),
      min_confidence: parse_confidence(params["min_confidence"]),
      no_db: params["no_db"] == true,
      no_user: params["no_user"] == true,
      changed_lines: scope[:changed_lines]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Keyword.merge(scope_files(root, scope))
    |> Keyword.put(:lift_test_exclusion, false)
  end

  # A diff-derived or user-supplied file list is explicit; the config's
  # `included` patterns must not add to it. When no scope is given we pass no
  # `:files_included` at all so `Execution` falls back to the config --
  # defaulting to the current directory instead would sweep `deps/` and
  # `_build/` into the analysis.
  defp scope_files(_root, %{kind: :config}), do: []

  defp scope_files(root, %{files: files}) do
    [files_included: Enum.map(files, &Path.expand(&1, root))]
  end

  defp parse_categories(nil), do: nil
  defp parse_categories([]), do: nil

  defp parse_categories(value) when is_binary(value) do
    value |> String.split(",", trim: true) |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))
  end

  defp parse_categories(value) when is_list(value),
    do: Enum.map(value, &(&1 |> to_string() |> String.to_atom()))

  defp parse_confidence(nil), do: nil
  defp parse_confidence(value), do: MetaCredo.Issue.parse_confidence(value)

  # ----- Normalization -------------------------------------------------------

  defp normalize_issue(issue, strip_prefix) do
    %{
      check: short_check_name(issue.check),
      category: issue.category,
      severity: issue.severity,
      priority: issue.priority,
      confidence: issue.confidence,
      message: issue.message,
      file: relativize(issue.filename, strip_prefix),
      line: issue.line_no,
      column: issue.column,
      trigger: issue.trigger
    }
  end

  # `MetaCredo.Check.Security.HardcodedValue` reads better as
  # `Security.HardcodedValue` in a report than as a fully-qualified module.
  defp short_check_name(check) when is_atom(check) do
    check
    |> Module.split()
    |> Enum.drop_while(&(&1 == "MetaCredo" or &1 == "Check"))
    |> Enum.join(".")
  end

  defp short_check_name(other), do: to_string(other)

  defp relativize(nil, _prefix), do: nil
  defp relativize(filename, nil), do: filename
  defp relativize(filename, prefix), do: Path.relative_to(filename, prefix)

  defp normalize(report, scope) do
    strip_prefix = scope[:strip_prefix]

    %{
      total: length(report.issues),
      by_category: report.summary.by_category,
      by_severity: report.summary.by_severity,
      by_check: report.summary.by_check |> Map.new(fn {k, v} -> {short_check_name(k), v} end),
      files_analyzed: length(report.source_files),
      checks_run: length(report.checks_run),
      timing_ms: report.timing_ms,
      # A diff that resolved to no files is not a clean bill of health; say so
      # rather than reporting "0 issues" and letting CI pass on nothing.
      partial: scope[:kind] == :diff and scope[:diff][:files_changed] == 0,
      diff: scope[:diff],
      issues: Enum.map(report.issues, &normalize_issue(&1, strip_prefix))
    }
  end

  # ----- Formatting ----------------------------------------------------------

  defp format(report, "summary", scope) do
    data = normalize(report, scope)

    {:ok,
     Map.take(data, [
       :total,
       :by_category,
       :by_severity,
       :by_check,
       :files_analyzed,
       :checks_run,
       :timing_ms,
       :partial,
       :diff
     ])
     |> Map.merge(%{status: "success", source: "metacredo"})}
  end

  defp format(report, "detailed", scope) do
    data = normalize(report, scope)
    {:ok, data |> Map.drop([:by_check]) |> Map.merge(%{status: "success", source: "metacredo"})}
  end

  defp format(report, "github", scope) do
    data = normalize(report, scope)

    annotations = Enum.map(data.issues, &github_annotation/1)

    {:ok,
     %{
       status: "success",
       source: "metacredo",
       total: data.total,
       annotations: annotations
     }}
  end

  defp format(_report, other, _scope), do: {:error, "Unknown format: #{inspect(other)}"}

  # GitHub Actions workflow commands. The `file=` value must be repo-relative
  # or the annotation is silently dropped, which is why `normalize_issue/2`
  # strips the prefix before we get here.
  defp github_annotation(issue) do
    level = github_level(issue.severity)

    location =
      ["file=#{issue.file || "unknown"}"] ++
        if(issue.line, do: ["line=#{issue.line}"], else: []) ++
        if(issue.column, do: ["col=#{issue.column}"], else: [])

    "::#{level} #{Enum.join(location, ",")}::#{issue.check}: #{issue.message}"
  end

  defp github_level(:error), do: "error"
  defp github_level(:warning), do: "warning"
  defp github_level(_), do: "notice"

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
