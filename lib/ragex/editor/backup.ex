defmodule Ragex.Editor.Backup do
  @moduledoc """
  Backup management for file editing operations.

  Creates, lists, and restores backups of files before editing.
  Backups are stored in a project-specific directory with timestamps.
  """

  alias Ragex.Editor.Types
  require Logger

  @doc """
  Creates a backup of a file.

  ## Parameters
  - `path`: Path to the file to backup
  - `opts`: Options
    - `:backup_dir` - Custom backup directory (optional)
    - `:compress` - Compress backup with gzip (default: false)

  ## Returns
  - `{:ok, backup_info}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> Backup.create("/path/to/file.ex")
      {:ok, %{id: "20240101_120000_abc123", ...}}
  """
  @spec create(String.t(), keyword()) :: {:ok, Types.backup_info()} | {:error, term()}
  def create(path, opts \\ []) do
    with {:ok, abs_path} <- ensure_absolute_path(path),
         {:ok, content} <- File.read(abs_path),
         {:ok, stat} <- File.stat(abs_path),
         backup_dir <- get_backup_dir(abs_path, opts),
         :ok <- File.mkdir_p(backup_dir),
         backup_id <- generate_backup_id(),
         backup_path <- Path.join(backup_dir, backup_id),
         :ok <- write_backup(backup_path, content, opts) do
      info =
        Types.backup_info(backup_id, abs_path, backup_path,
          size: byte_size(content),
          original_mtime: stat.mtime |> to_unix_time()
        )

      Logger.debug("Created backup: #{backup_id} for #{abs_path}")
      {:ok, info}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create backup for #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Lists all backups for a file.

  ## Parameters
  - `path`: Path to the file
  - `opts`: Options
    - `:backup_dir` - Custom backup directory (optional)
    - `:limit` - Maximum number of backups to return (default: 10)

  ## Returns
  List of backup info structs, sorted by creation time (newest first).
  """
  @spec list(String.t(), keyword()) :: {:ok, [Types.backup_info()]} | {:error, term()}
  def list(path, opts \\ []) do
    with {:ok, abs_path} <- ensure_absolute_path(path),
         backup_dir <- get_backup_dir(abs_path, opts),
         {:ok, files} <- safe_list_dir(backup_dir) do
      limit = Keyword.get(opts, :limit, 10)

      backups =
        files
        |> Enum.filter(&is_backup_file?/1)
        |> Enum.map(fn filename ->
          backup_path = Path.join(backup_dir, filename)

          case File.stat(backup_path) do
            {:ok, stat} ->
              Types.backup_info(filename, abs_path, backup_path,
                size: stat.size,
                created_at: stat.ctime |> to_datetime()
              )

            {:error, _} ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
        |> Enum.take(limit)

      {:ok, backups}
    end
  end

  @doc """
  Restores a file from a backup.

  ## Parameters
  - `path`: Path to the file to restore
  - `backup_id`: ID of the backup to restore (if nil, restores most recent)
  - `opts`: Options
    - `:backup_dir` - Custom backup directory (optional)
    - `:delete_backup` - Delete backup after restore (default: false)

  ## Returns
  - `{:ok, backup_info}` on success
  - `{:error, reason}` on failure
  """
  @spec restore(String.t(), String.t() | nil, keyword()) ::
          {:ok, Types.backup_info()} | {:error, term()}
  def restore(path, backup_id \\ nil, opts \\ []) do
    with {:ok, abs_path} <- ensure_absolute_path(path),
         {:ok, backups} <- list(abs_path, opts),
         {:ok, backup} <- select_backup(backups, backup_id),
         {:ok, content} <- read_backup(backup.backup_path, opts),
         :ok <- File.write(abs_path, content) do
      Logger.info("Restored #{abs_path} from backup #{backup.id}")

      if Keyword.get(opts, :delete_backup, false) do
        File.rm(backup.backup_path)
      end

      {:ok, backup}
    else
      {:error, :no_backups} ->
        {:error, "No backups found for #{path}"}

      {:error, :backup_not_found} ->
        {:error, "Backup #{backup_id} not found"}

      {:error, reason} = error ->
        Logger.error("Failed to restore backup for #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Cleans up old backups for a file.

  ## Parameters
  - `path`: Path to the file
  - `opts`: Options
    - `:backup_dir` - Custom backup directory (optional)
    - `:keep` - Number of backups to keep (default: 10)

  ## Returns
  Number of backups deleted.
  """
  @spec cleanup(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup(path, opts \\ []) do
    keep = Keyword.get(opts, :keep, 10)

    with {:ok, backups} <- list(path, Keyword.put(opts, :limit, 1000)) do
      to_delete = Enum.drop(backups, keep)

      deleted =
        Enum.reduce(to_delete, 0, fn backup, count ->
          case File.rm(backup.backup_path) do
            :ok ->
              Logger.debug("Deleted old backup: #{backup.id}")
              count + 1

            {:error, reason} ->
              Logger.warning("Failed to delete backup #{backup.id}: #{inspect(reason)}")
              count
          end
        end)

      {:ok, deleted}
    end
  end

  @doc """
  Gets the total size of all backups for a file.
  """
  @spec total_size(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def total_size(path, opts \\ []) do
    with {:ok, backups} <- list(path, Keyword.put(opts, :limit, 1000)) do
      total = Enum.reduce(backups, 0, fn backup, acc -> acc + backup.size end)
      {:ok, total}
    end
  end

  # Private functions

  defp ensure_absolute_path(path) do
    {:ok, Path.expand(path)}
  end

  defp get_backup_dir(file_path, opts) do
    case Keyword.get(opts, :backup_dir) do
      nil ->
        # Use project-specific backup directory
        project_hash = compute_project_hash(file_path)

        base_dir =
          Application.get_env(:ragex, :editor, [])
          |> Keyword.get(:backup_dir, Path.expand("~/.ragex/backups"))

        Path.join([base_dir, project_hash, relative_path_hash(file_path)])

      custom_dir ->
        custom_dir
    end
  end

  defp compute_project_hash(file_path) do
    # Find the nearest git root or use the directory
    case find_git_root(file_path) do
      {:ok, git_root} ->
        :crypto.hash(:sha256, git_root)
        |> Base.encode16(case: :lower)
        |> String.slice(0, 12)

      :error ->
        # Use parent directory as fallback
        dir = Path.dirname(file_path)

        :crypto.hash(:sha256, dir)
        |> Base.encode16(case: :lower)
        |> String.slice(0, 12)
    end
  end

  defp find_git_root(path, depth \\ 0)
  defp find_git_root(_path, depth) when depth > 10, do: :error

  defp find_git_root(path, depth) do
    dir = if File.dir?(path), do: path, else: Path.dirname(path)
    git_dir = Path.join(dir, ".git")

    if File.dir?(git_dir) do
      {:ok, dir}
    else
      parent = Path.dirname(dir)

      if parent == dir do
        :error
      else
        find_git_root(parent, depth + 1)
      end
    end
  end

  defp relative_path_hash(file_path) do
    # Create a hash of the relative file path for organizing backups
    filename = Path.basename(file_path)

    :crypto.hash(:sha256, file_path)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
    |> then(&"#{filename}_#{&1}")
  end

  defp generate_backup_id do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")

    random =
      :crypto.strong_rand_bytes(4)
      |> Base.encode16(case: :lower)

    "#{timestamp}_#{random}"
  end

  defp write_backup(backup_path, content, opts) do
    compress = Keyword.get(opts, :compress, false)

    content_to_write =
      if compress do
        :zlib.gzip(content)
      else
        content
      end

    final_path =
      if compress do
        "#{backup_path}.gz"
      else
        backup_path
      end

    File.write(final_path, content_to_write)
  end

  defp read_backup(backup_path, _opts) do
    compressed? = String.ends_with?(backup_path, ".gz")

    with {:ok, content} <- File.read(backup_path) do
      if compressed? do
        {:ok, :zlib.gunzip(content)}
      else
        {:ok, content}
      end
    end
  end

  defp safe_list_dir(dir) do
    case File.ls(dir) do
      {:ok, files} -> {:ok, files}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp is_backup_file?(filename) do
    # Backup files match pattern: YYYYMMDD_HHMMSS_randomhex[.gz]
    String.match?(filename, ~r/^\d{8}_\d{6}_[0-9a-f]+(.gz)?$/)
  end

  defp select_backup([], _backup_id), do: {:error, :no_backups}

  defp select_backup(backups, nil) do
    # Return most recent (first in list, already sorted)
    {:ok, List.first(backups)}
  end

  defp select_backup(backups, backup_id) do
    case Enum.find(backups, &(&1.id == backup_id)) do
      nil -> {:error, :backup_not_found}
      backup -> {:ok, backup}
    end
  end

  defp to_unix_time({{year, month, day}, {hour, minute, second}}) do
    {:ok, dt} = NaiveDateTime.new(year, month, day, hour, minute, second)
    {:ok, datetime} = DateTime.from_naive(dt, "Etc/UTC")
    DateTime.to_unix(datetime)
  end

  defp to_datetime({{year, month, day}, {hour, minute, second}}) do
    {:ok, dt} = NaiveDateTime.new(year, month, day, hour, minute, second)
    {:ok, datetime} = DateTime.from_naive(dt, "Etc/UTC")
    datetime
  end
end
