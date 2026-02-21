defmodule Ragex.Analysis.Cache do
  @moduledoc """
  Persistence layer for code analysis results (issues).

  Caches issue discovery results (dead code, security, smells, duplicates, etc.)
  alongside file fingerprints. On load, compares stored fingerprints with current
  file state to determine cache freshness.

  Data is stored at `~/.cache/ragex/<project_hash>/analysis.etf`.

  ## Usage

      # Save analysis results
      :ok = Analysis.Cache.save(issues, "/path/to/project")

      # Load cached results (validates freshness)
      {:ok, issues} = Analysis.Cache.load("/path/to/project")
      {:stale, cached_issues, changed_files} = Analysis.Cache.load("/path/to/project")

      # Check cache freshness
      Analysis.Cache.fresh?("/path/to/project")
  """

  require Logger

  alias Ragex.Embeddings.FileTracker
  alias Ragex.Embeddings.Persistence, as: EmbeddingsPersistence

  @version 1
  @cache_file_name "analysis.etf"

  @doc """
  Saves analysis results to disk with file fingerprints.

  ## Parameters

  - `issues` - Map of issue categories to their results
  - `path` - Project path that was analyzed

  ## Returns

  - `:ok` - Saved successfully
  - `{:error, reason}` - Failure
  """
  @spec save(map(), String.t()) :: :ok | {:error, term()}
  def save(issues, path) do
    cache_path = get_cache_path()
    cache_dir = Path.dirname(cache_path)

    File.mkdir_p!(cache_dir)

    # Snapshot current file fingerprints
    fingerprints = build_fingerprint_snapshot()

    data = %{
      version: @version,
      timestamp: System.system_time(:second),
      project_path: path,
      fingerprints: fingerprints,
      issues: issues
    }

    binary = :erlang.term_to_binary(data, [:compressed])
    File.write!(cache_path, binary)

    Logger.info("Saved analysis cache: #{map_size(fingerprints)} file fingerprints")
    :ok
  rescue
    e ->
      Logger.error("Failed to save analysis cache: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Loads cached analysis results and validates freshness.

  ## Parameters

  - `path` - Project path to validate against

  ## Returns

  - `{:ok, issues}` - Cache is fresh, all files unchanged
  - `{:stale, issues, changed_files}` - Some files changed, returns cached issues + list of changed files
  - `{:error, :not_found}` - No cache exists
  - `{:error, reason}` - Failure
  """
  @spec load(String.t()) :: {:ok, map()} | {:stale, map(), [String.t()]} | {:error, term()}
  def load(path) do
    cache_path = get_cache_path()

    if File.exists?(cache_path) do
      do_load(cache_path, path)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Checks if the analysis cache is fresh (all files unchanged).
  """
  @spec fresh?(String.t()) :: boolean()
  def fresh?(path) do
    case load(path) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Clears the analysis cache.
  """
  @spec clear() :: :ok
  def clear do
    cache_path = get_cache_path()

    if File.exists?(cache_path) do
      File.rm!(cache_path)
      Logger.info("Cleared analysis cache: #{cache_path}")
    end

    :ok
  end

  @doc """
  Returns statistics about the analysis cache.
  """
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    cache_path = get_cache_path()

    if File.exists?(cache_path) do
      stat = File.stat!(cache_path)

      case read_metadata(cache_path) do
        {:ok, metadata} ->
          {:ok,
           %{
             cache_path: cache_path,
             file_size: stat.size,
             timestamp: metadata.timestamp,
             file_count: map_size(metadata.fingerprints),
             project_path: metadata.project_path
           }}

        error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  # Private functions

  defp do_load(cache_path, path) do
    binary = File.read!(cache_path)
    data = :erlang.binary_to_term(binary)

    case data do
      %{version: @version, project_path: ^path, fingerprints: fingerprints, issues: issues} ->
        changed_files = find_changed_files(fingerprints)

        if changed_files == [] do
          Logger.info("Analysis cache is fresh (#{map_size(fingerprints)} files unchanged)")
          {:ok, issues}
        else
          Logger.info(
            "Analysis cache is stale: #{length(changed_files)}/#{map_size(fingerprints)} files changed"
          )

          {:stale, issues, changed_files}
        end

      %{version: @version, project_path: cached_path} ->
        Logger.info("Analysis cache path mismatch: cached=#{cached_path}, requested=#{path}")
        {:error, :path_mismatch}

      %{version: version} ->
        Logger.warning("Analysis cache version mismatch: expected #{@version}, got #{version}")
        {:error, :version_mismatch}

      _ ->
        {:error, :invalid_format}
    end
  rescue
    e ->
      Logger.error("Failed to load analysis cache: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp build_fingerprint_snapshot do
    FileTracker.list_tracked_files()
    |> Enum.into(%{}, fn {path, metadata} ->
      {path, metadata.content_hash}
    end)
  end

  defp find_changed_files(cached_fingerprints) do
    cached_fingerprints
    |> Enum.filter(fn {path, cached_hash} ->
      case FileTracker.has_changed?(path) do
        {:unchanged, %{content_hash: ^cached_hash}} -> false
        {:unchanged, _} -> true
        {:changed, _} -> true
        {:deleted, _} -> true
        {:new, _} -> true
      end
    end)
    |> Enum.map(fn {path, _} -> path end)
  end

  defp read_metadata(cache_path) do
    binary = File.read!(cache_path)

    case :erlang.binary_to_term(binary) do
      %{version: v, timestamp: t, fingerprints: f, project_path: p} ->
        {:ok, %{version: v, timestamp: t, fingerprints: f, project_path: p}}

      _ ->
        {:error, :no_metadata}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp get_cache_path do
    cache_dir =
      Application.get_env(:ragex, :cache_root, EmbeddingsPersistence.default_cache_root())

    project_hash = EmbeddingsPersistence.generate_project_hash()

    Path.join([cache_dir, project_hash, @cache_file_name])
  end
end
