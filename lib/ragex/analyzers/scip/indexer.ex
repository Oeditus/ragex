defmodule Ragex.Analyzers.SCIP.Indexer do
  @moduledoc """
  Orchestrates external SCIP indexer binaries.

  Runs the appropriate SCIP indexer (e.g. `scip-go`, `rust-analyzer`,
  `scip-java`) in the project directory, producing an `index.scip` file.
  Then converts it to JSON via `scip print --json` for parsing.

  All external processes run with configurable timeouts and are killed
  if they exceed the limit.

  ## Flow

  1. Detect language from project marker files
  2. Check that the indexer binary is available
  3. Run the indexer -> produces `index.scip`
  4. Run `scip print --json index.scip` -> JSON output
  5. Return JSON string for the Parser to consume

  ## Configuration

      config :ragex, :scip,
        indexer_timeout: 300_000,   # 5 minutes default
        index_file: "index.scip"   # default output filename
  """

  require Logger

  alias Ragex.Analyzers.SCIP.Registry

  @default_timeout 300_000
  @default_index_file "index.scip"

  @doc """
  Run a SCIP indexer for the given language in the project directory.

  Returns `{:ok, json_string}` with the JSON representation of the
  SCIP index, or `{:error, reason}`.

  ## Options
  - `:timeout` -- max time for the indexer to run (default 5 min)
  - `:index_file` -- output filename (default "index.scip")
  """
  @spec index(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def index(project_dir, language, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, scip_config(:indexer_timeout, @default_timeout))
    index_file = Keyword.get(opts, :index_file, scip_config(:index_file, @default_index_file))

    with {:ok, lang_info} <- find_language(language),
         :ok <- check_indexer(lang_info.indexer),
         :ok <- check_scip_cli(),
         {:ok, _} <- run_indexer(project_dir, lang_info, index_file, timeout) do
      convert_to_json(project_dir, index_file)
    end
  end

  @doc """
  Auto-detect languages and index all of them.

  Returns `{:ok, results}` where results is a map of
  `%{language => {:ok, json} | {:error, reason}}`.
  """
  @spec index_all(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def index_all(project_dir, opts \\ []) do
    languages = Registry.detect_languages(project_dir)

    if languages == [] do
      {:ok, %{}}
    else
      results =
        Map.new(languages, fn lang ->
          Logger.info("SCIP: indexing #{lang.language} in #{project_dir}")
          result = index(project_dir, lang.language, opts)
          {lang.language, result}
        end)

      {:ok, results}
    end
  end

  @doc """
  Check if a SCIP index file already exists for a project.

  Returns the path if found, nil otherwise.
  """
  @spec find_existing_index(String.t()) :: String.t() | nil
  def find_existing_index(project_dir) do
    index_file = scip_config(:index_file, @default_index_file)
    path = Path.join(project_dir, index_file)
    if File.exists?(path), do: path
  end

  @doc """
  Convert an existing SCIP index file to JSON using the `scip` CLI.

  Useful when the index was generated externally (e.g. by CI).
  """
  @spec convert_to_json(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def convert_to_json(project_dir, index_file \\ @default_index_file) do
    index_path = Path.join(project_dir, index_file)

    if File.exists?(index_path) do
      args = ["print", "--json", index_path]

      case System.cmd("scip", args, cd: project_dir, stderr_to_stdout: true) do
        {json, 0} -> {:ok, json}
        {err, code} -> {:error, {:scip_print_failed, err, code}}
      end
    else
      {:error, {:index_not_found, index_path}}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp find_language(language) do
    case Registry.get_language(language) do
      nil -> {:error, {:unknown_language, language}}
      info -> {:ok, info}
    end
  end

  defp check_indexer(indexer_name) do
    if System.find_executable(indexer_name) do
      :ok
    else
      {:error, {:indexer_not_found, indexer_name}}
    end
  end

  defp check_scip_cli do
    if Registry.scip_cli_available?() do
      :ok
    else
      {:error, :scip_cli_not_found}
    end
  end

  defp run_indexer(project_dir, lang_info, _index_file, timeout) do
    args = lang_info.indexer_args
    indexer = lang_info.indexer

    Logger.info("SCIP: running #{indexer} #{Enum.join(args, " ")} in #{project_dir}")

    task =
      Task.async(fn ->
        System.cmd(indexer, args, cd: project_dir, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        {:ok, :indexed}

      {:ok, {output, code}} ->
        Logger.warning(
          "SCIP indexer #{indexer} exited with code #{code}: #{String.slice(output, 0, 500)}"
        )

        {:error, {:indexer_failed, indexer, code}}

      nil ->
        Logger.error("SCIP indexer #{indexer} timed out after #{timeout}ms")
        {:error, {:indexer_timeout, indexer}}
    end
  end

  defp scip_config(key, default) do
    Application.get_env(:ragex, :scip, []) |> Keyword.get(key, default)
  end
end
