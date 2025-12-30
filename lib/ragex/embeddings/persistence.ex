defmodule Ragex.Embeddings.Persistence do
  @moduledoc """
  Persistence layer for embedding vectors.

  Saves and loads embeddings to/from disk to avoid regeneration on restart.
  Uses ETS serialization for fast I/O and includes metadata for validation.
  """

  require Logger
  alias Ragex.Graph.Store
  alias Ragex.Embeddings.Registry

  @version 1
  @cache_file_name "embeddings.ets"

  @type cache_metadata :: %{
          version: integer(),
          model_id: atom(),
          model_repo: String.t(),
          dimensions: pos_integer(),
          timestamp: integer(),
          entity_count: non_neg_integer()
        }

  @doc """
  Saves embeddings to disk.

  Can be called with:
  - ETS table reference (for tests/direct use)
  - No arguments (uses Store.embeddings_table())

  ## Returns
  - `{:ok, path}` - Success with cache file path
  - `{:error, reason}` - Failure reason
  """
  @spec save(atom() | reference()) :: {:ok, Path.t()} | {:error, term()}
  def save(table_or_opts \\ nil)

  def save(nil), do: save(Store.embeddings_table())

  def save(table) when is_reference(table) or is_atom(table) do
    do_save(table)
  end

  @doc """
  Loads embeddings from disk if available and valid.

  Validates:
  - Model compatibility (same model ID or compatible dimensions)
  - Cache version
  - File integrity

  ## Returns
  - `{:ok, count}` - Successfully loaded count embeddings
  - `{:error, :not_found}` - No cache file exists
  - `{:error, :incompatible_model}` - Model mismatch
  - `{:error, reason}` - Other failure
  """
  @spec load() :: {:ok, non_neg_integer()} | {:error, term()}
  def load do
    config = Application.get_env(:ragex, :cache, enabled: true)
    enabled = Keyword.get(config, :enabled, true)

    if not enabled do
      {:error, :cache_disabled}
    else
      do_load()
    end
  end

  @doc """
  Clears cached embeddings from disk.

  ## Modes
  - `:current` - Clear current project cache
  - `:all` - Clear all caches
  - `{:older_than, days}` - Clear caches older than N days

  ## Returns
  - `:ok` - Success
  - `{:error, reason}` - Failure reason
  """
  @spec clear(atom() | {atom(), integer()}) :: :ok | {:error, term()}
  def clear(mode \\ :current)

  def clear(:current), do: clear_current_cache()
  def clear(:all), do: clear_all_caches()
  def clear({:older_than, days}) when is_integer(days), do: clear_old_caches(days)

  @doc """
  Gets statistics about the cache.

  Returns information about cache file, size, age, and contents.
  """
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    cache_path = get_cache_path()

    if File.exists?(cache_path) do
      stat = File.stat!(cache_path)

      # Try to read metadata without loading full cache
      case read_metadata(cache_path) do
        {:ok, metadata} ->
          current_model_id = Application.get_env(:ragex, :embedding_model, Registry.default())

          is_valid =
            metadata.model_id == current_model_id or
              Registry.compatible?(metadata.model_id, current_model_id)

          {:ok,
           %{
             cache_path: cache_path,
             file_size: stat.size,
             metadata: metadata,
             valid?: is_valid
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Returns the cache path for the current project.
  """
  def cache_path, do: get_cache_path()

  @doc """
  Returns the default cache root directory.
  """
  def default_cache_root do
    xdg_cache = System.get_env("XDG_CACHE_HOME")

    if xdg_cache && xdg_cache != "" do
      Path.join(xdg_cache, "ragex")
    else
      Path.expand("~/.cache/ragex")
    end
  end

  @doc """
  Checks if a valid cache exists for the current configuration.
  """
  @spec cache_valid?() :: boolean()
  def cache_valid? do
    cache_path = get_cache_path()

    if File.exists?(cache_path) do
      case read_metadata(cache_path) do
        {:ok, metadata} ->
          current_model_id = Application.get_env(:ragex, :embedding_model, Registry.default())

          # Check if models are compatible
          metadata.model_id == current_model_id or
            Registry.compatible?(metadata.model_id, current_model_id)

        {:error, _} ->
          false
      end
    else
      false
    end
  end

  # Private Functions

  defp do_save(table) do
    try do
      cache_path = get_cache_path()
      cache_dir = Path.dirname(cache_path)

      # Ensure cache directory exists
      File.mkdir_p!(cache_dir)

      # Get current model info
      model_id = Application.get_env(:ragex, :embedding_model, Registry.default())
      {:ok, model_info} = Registry.get(model_id)

      # Get embeddings from the provided table
      embeddings = get_embeddings_from_table(table)

      # Export file tracking data
      file_tracking = Ragex.Embeddings.FileTracker.export()

      # Build metadata
      metadata = %{
        version: @version,
        model_id: model_id,
        model_repo: model_info.repo,
        dimensions: model_info.dimensions,
        timestamp: System.system_time(:second),
        entity_count: length(embeddings),
        file_tracking: file_tracking
      }

      # Create temporary ETS table for serialization
      temp_table = :ets.new(:temp_embeddings, [:set, :public])

      # Insert metadata as first entry
      :ets.insert(temp_table, {:__metadata__, metadata})

      # Insert all embeddings
      for {node_type, node_id, embedding, text} <- embeddings do
        key = {node_type, node_id}
        :ets.insert(temp_table, {key, embedding, text})
      end

      # Write to disk
      :ets.tab2file(temp_table, String.to_charlist(cache_path))

      # Clean up
      :ets.delete(temp_table)

      Logger.info("Saved #{length(embeddings)} embeddings to cache: #{cache_path}")
      {:ok, cache_path}
    rescue
      e ->
        Logger.error("Failed to save embeddings cache: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  defp do_load do
    cache_path = get_cache_path()

    if not File.exists?(cache_path) do
      {:error, :not_found}
    else
      try do
        # Read metadata first to validate
        case read_metadata(cache_path) do
          {:ok, metadata} ->
            # Validate version
            if metadata.version != @version do
              Logger.warning(
                "Cache version mismatch: expected #{@version}, got #{metadata.version}"
              )

              {:error, :version_mismatch}
            else
              # Validate model compatibility
              current_model_id = Application.get_env(:ragex, :embedding_model, Registry.default())

              compatible =
                if metadata.model_id == current_model_id do
                  true
                else
                  Registry.compatible?(metadata.model_id, current_model_id)
                end

              if compatible do
                if metadata.model_id != current_model_id do
                  Logger.info(
                    "Loading cache from compatible model: #{metadata.model_id} (#{metadata.dimensions} dims)"
                  )
                end

                # Load the cache
                load_cache(cache_path, metadata)
              else
                Logger.warning(
                  "Model incompatibility: cache=#{metadata.model_id} (#{metadata.dimensions} dims), current=#{current_model_id}"
                )

                {:error, :incompatible}
              end
            end

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        e ->
          Logger.error("Failed to load embeddings cache: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end
    end
  end

  defp load_cache(cache_path, metadata) do
    # Load ETS table from file
    {:ok, temp_table} = :ets.file2tab(String.to_charlist(cache_path))

    # Skip metadata entry and load all embeddings
    embeddings =
      :ets.tab2list(temp_table)
      |> Enum.reject(fn
        {:__metadata__, _} -> true
        _ -> false
      end)

    # Store in graph store
    count =
      Enum.reduce(embeddings, 0, fn {{node_type, node_id}, embedding, text}, acc ->
        Store.store_embedding(node_type, node_id, embedding, text)
        acc + 1
      end)

    # Import file tracking data if available
    if Map.has_key?(metadata, :file_tracking) do
      case Ragex.Embeddings.FileTracker.import(metadata.file_tracking) do
        :ok ->
          Logger.debug("Loaded file tracking data")

        {:error, reason} ->
          Logger.warning("Failed to load file tracking data: #{inspect(reason)}")
      end
    end

    # Clean up
    :ets.delete(temp_table)

    Logger.info(
      "Loaded #{count} embeddings from cache (model: #{metadata.model_id}, #{metadata.dimensions} dims)"
    )

    {:ok, count}
  end

  defp read_metadata(cache_path) do
    try do
      # Load table temporarily to read metadata
      {:ok, temp_table} = :ets.file2tab(String.to_charlist(cache_path))

      case :ets.lookup(temp_table, :__metadata__) do
        [{:__metadata__, metadata}] ->
          :ets.delete(temp_table)
          {:ok, metadata}

        [] ->
          :ets.delete(temp_table)
          {:error, :no_metadata}
      end
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  defp clear_current_cache do
    cache_path = get_cache_path()

    if File.exists?(cache_path) do
      File.rm!(cache_path)
      Logger.info("Cleared cache: #{cache_path}")
    end

    :ok
  end

  defp clear_all_caches do
    cache_root = Application.get_env(:ragex, :cache_root, default_cache_root())

    if File.exists?(cache_root) do
      # Clear all project directories
      File.ls!(cache_root)
      |> Enum.each(fn project_hash ->
        project_dir = Path.join(cache_root, project_hash)

        if File.dir?(project_dir) do
          File.rm_rf!(project_dir)
        end
      end)

      Logger.info("Cleared all caches from #{cache_root}")
    end

    :ok
  end

  defp clear_old_caches(days) do
    cache_root = Application.get_env(:ragex, :cache_root, default_cache_root())

    if File.exists?(cache_root) do
      cutoff_time = System.system_time(:second) - days * 86400

      File.ls!(cache_root)
      |> Enum.each(fn project_hash ->
        cache_file = Path.join([cache_root, project_hash, @cache_file_name])

        if File.exists?(cache_file) do
          stat = File.stat!(cache_file)
          mtime_unix = :calendar.datetime_to_gregorian_seconds(stat.mtime) - 62_167_219_200

          if mtime_unix < cutoff_time do
            project_dir = Path.dirname(cache_file)
            File.rm_rf!(project_dir)
          end
        end
      end)

      Logger.info("Cleared caches older than #{days} days")
    end

    :ok
  end

  defp get_embeddings_from_table(table) do
    # Read all entries from the table, excluding metadata
    :ets.tab2list(table)
    |> Enum.reject(fn
      {:__metadata__, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {{node_type, node_id}, embedding, text} ->
      {node_type, node_id, embedding, text}
    end)
  end

  defp get_cache_path do
    cache_dir = get_cache_dir()
    project_hash = generate_project_hash()

    Path.join([cache_dir, project_hash, @cache_file_name])
  end

  defp get_cache_dir do
    Application.get_env(:ragex, :cache_root, default_cache_root())
  end

  @doc """
  Generates a unique hash for the current project directory.

  This ensures different projects have separate caches.
  Uses the absolute path of the current working directory.
  """
  def generate_project_hash do
    cwd = File.cwd!()

    :crypto.hash(:sha256, cwd)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
