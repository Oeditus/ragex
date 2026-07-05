defmodule Ragex.Embeddings.FileTracker do
  @moduledoc """
  Tracks file metadata to enable incremental embedding updates.

  This module maintains a registry of analyzed files with their content hashes,
  modification times, and associated entities (modules, functions). It enables
  smart diff detection to determine which embeddings need regeneration when
  files change.

  ## Strategy

  1. **Content Hashing**: SHA256 hash of file content for reliable change detection
  2. **Entity Tracking**: Map files to their contained entities (modules, functions)
  3. **Incremental Updates**: Only regenerate embeddings for changed files
  4. **Performance**: <5% regeneration on typical single-file changes

  ## Usage

      # Track a file after analysis
      FileTracker.track_file("/path/to/file.ex", analysis_result)
      
      # Check if file has changed
      FileTracker.has_changed?("/path/to/file.ex")
      
      # Get entities that need regeneration
      FileTracker.get_stale_entities()
      
      # Clear tracking for deleted files
      FileTracker.untrack_file("/path/to/file.ex")
  """

  require Logger

  @tracker_table :ragex_file_tracker
  # Per-entity body hashes. Key: {file_path, entity_id}, value: sha256 binary.
  @fn_hash_table :ragex_fn_hash_tracker

  @type file_metadata :: %{
          path: String.t(),
          content_hash: binary(),
          mtime: integer(),
          size: integer(),
          entities: [entity_ref()],
          analyzed_at: integer()
        }

  @type entity_ref :: {:module, term()} | {:function, term()}

  ## Public API

  @doc """
  Initializes the file tracker ETS table.

  Called automatically by the application supervisor.
  """
  def init do
    case :ets.whereis(@tracker_table) do
      :undefined ->
        :ets.new(@tracker_table, [:named_table, :set, :public, read_concurrency: true])
        Logger.debug("File tracker initialized")

      _table ->
        Logger.debug("File tracker already initialized")
    end

    case :ets.whereis(@fn_hash_table) do
      :undefined ->
        :ets.new(@fn_hash_table, [:named_table, :set, :public, read_concurrency: true])

      _table ->
        :ok
    end

    :ok
  end

  @doc """
  Tracks a file with its metadata and associated entities.

  ## Parameters

  - `file_path` - Absolute path to the file
  - `analysis_result` - Analysis result containing modules and functions

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  def track_file(file_path, analysis_result) do
    case compute_file_metadata(file_path, analysis_result) do
      {:ok, metadata} ->
        :ets.insert(@tracker_table, {file_path, metadata})
        Logger.debug("Tracked file: #{file_path} (#{length(metadata.entities)} entities)")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to track file #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Checks if a file has changed since it was last tracked.

  Returns `{:changed, old_metadata}` if the file has changed,
  `{:unchanged, metadata}` if it hasn't, or
  `{:new, nil}` if the file was never tracked.
  """
  def has_changed?(file_path) do
    case :ets.lookup(@tracker_table, file_path) do
      [{^file_path, old_metadata}] ->
        case compute_current_hash(file_path) do
          {:ok, current_hash} ->
            if current_hash == old_metadata.content_hash do
              {:unchanged, old_metadata}
            else
              {:changed, old_metadata}
            end

          {:error, :enoent} ->
            # File was deleted
            {:deleted, old_metadata}

          {:error, _reason} ->
            # Assume changed if we can't read it
            {:changed, old_metadata}
        end

      [] ->
        {:new, nil}
    end
  end

  @doc """
  Returns a list of all tracked files.
  """
  def list_tracked_files do
    :ets.tab2list(@tracker_table)
    |> Enum.map(fn {path, metadata} -> {path, metadata} end)
  end

  @doc """
  Returns entities from files that have changed.

  This is used to determine which embeddings need to be regenerated.
  Returns a list of `{entity_type, entity_id}` tuples.
  """
  def get_stale_entities do
    list_tracked_files()
    |> Enum.flat_map(fn {file_path, metadata} ->
      case has_changed?(file_path) do
        {:changed, _} -> metadata.entities
        {:deleted, _} -> metadata.entities
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Removes tracking for a file.

  Used when files are deleted or need to be re-analyzed from scratch.
  """
  def untrack_file(file_path) do
    :ets.delete(@tracker_table, file_path)
    Logger.debug("Untracked file: #{file_path}")
    :ok
  end

  @doc """
  Records per-entity body hashes for a file.

  `entities` is a list of `{entity_id, body_text}` pairs where `entity_id` is
  the same tuple stored in file metadata (e.g. `{module, name, arity}` for a
  function). A SHA256 of `body_text` is stored so future calls to
  `stale_entities_for_file/2` can identify which functions actually changed.
  """
  @spec record_entity_hashes(String.t(), [{term(), String.t()}]) :: :ok
  def record_entity_hashes(file_path, entities) do
    Enum.each(entities, fn {entity_id, body} ->
      hash = :crypto.hash(:sha256, body)
      :ets.insert(@fn_hash_table, {{file_path, entity_id}, hash})
    end)

    :ok
  end

  @doc """
  Returns the subset of `entities` whose body hash has changed (or is new).

  `entities` is a list of `{entity_id, body_text}` pairs matching the format
  used by `record_entity_hashes/2`. Returns a `MapSet` of entity IDs for those
  whose hash differs from the stored value, enabling callers to skip unchanged
  ones.

  When no hash has been stored for a file yet (first analysis) every entity is
  considered stale so all embeddings are generated.
  """
  @spec stale_entities_for_file(String.t(), [{term(), String.t()}]) :: MapSet.t()
  def stale_entities_for_file(file_path, entities) do
    entities
    |> Enum.filter(fn {entity_id, body} ->
      new_hash = :crypto.hash(:sha256, body)

      case :ets.lookup(@fn_hash_table, {file_path, entity_id}) do
        [{{^file_path, ^entity_id}, stored_hash}] -> new_hash != stored_hash
        [] -> true
      end
    end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  @doc """
  Clears all tracked files.

  Used when performing a full refresh or clearing the cache.
  """
  def clear_all do
    :ets.delete_all_objects(@tracker_table)
    :ets.delete_all_objects(@fn_hash_table)
    Logger.info("Cleared all file tracking data")
    :ok
  end

  @doc """
  Returns statistics about tracked files.
  """
  def stats do
    tracked_files = list_tracked_files()
    total_files = length(tracked_files)

    {changed, unchanged, deleted} =
      Enum.reduce(tracked_files, {0, 0, 0}, fn {file_path, _metadata}, {ch, un, del} ->
        case has_changed?(file_path) do
          {:changed, _} -> {ch + 1, un, del}
          {:unchanged, _} -> {ch, un + 1, del}
          {:deleted, _} -> {ch, un, del + 1}
          _ -> {ch, un, del}
        end
      end)

    total_entities =
      tracked_files
      |> Enum.reduce(0, fn {_, metadata}, acc -> acc + length(metadata.entities) end)

    %{
      total_files: total_files,
      changed_files: changed,
      unchanged_files: unchanged,
      deleted_files: deleted,
      total_entities: total_entities,
      stale_entities: length(get_stale_entities())
    }
  end

  @doc """
  Exports tracking data for persistence.

  Returns a map that can be serialized and stored alongside embeddings.
  """
  def export do
    %{
      version: 1,
      tracked_files: list_tracked_files() |> Enum.into(%{})
    }
  end

  @doc """
  Imports tracking data from persistence.

  Restores file tracking state from a previously exported state.
  """
  def import(data) do
    case data do
      %{version: 1, tracked_files: files} when is_map(files) ->
        clear_all()

        Enum.each(files, fn {path, metadata} ->
          :ets.insert(@tracker_table, {path, metadata})
        end)

        Logger.info("Imported tracking data for #{map_size(files)} files")
        :ok

      _ ->
        Logger.warning("Invalid tracking data format, skipping import")
        {:error, :invalid_format}
    end
  end

  ## Private Functions

  defp compute_file_metadata(file_path, analysis_result) do
    with {:ok, content} <- File.read(file_path),
         {:ok, stat} <- File.stat(file_path) do
      # Compute content hash
      content_hash = :crypto.hash(:sha256, content)

      # Extract entity references from analysis
      entities = extract_entities(analysis_result)

      metadata = %{
        path: file_path,
        content_hash: content_hash,
        mtime: file_mtime_to_unix(stat.mtime),
        size: stat.size,
        entities: entities,
        analyzed_at: System.system_time(:second)
      }

      {:ok, metadata}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp compute_current_hash(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        {:ok, :crypto.hash(:sha256, content)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_entities(analysis_result) do
    module_entities =
      analysis_result.modules
      |> Enum.map(fn mod -> {:module, mod.name} end)

    function_entities =
      analysis_result.functions
      |> Enum.map(fn func -> {:function, {func.module, func.name, func.arity}} end)

    module_entities ++ function_entities
  end

  defp file_mtime_to_unix({{year, month, day}, {hour, min, sec}}) do
    # Convert Erlang datetime to Unix timestamp
    gregorian_seconds =
      :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, min, sec}})

    # Unix epoch offset
    gregorian_seconds - 62_167_219_200
  end
end
