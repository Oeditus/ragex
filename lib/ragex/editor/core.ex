defmodule Ragex.Editor.Core do
  @moduledoc """
  Core editing functionality with atomic operations and validation.

  Provides safe file editing with:
  - Automatic backups before editing
  - Atomic write operations
  - Concurrent modification detection
  - Rollback support
  - Integration with validation pipeline
  """

  alias Ragex.Editor.{Backup, Formatter, Types, Validator}
  require Logger

  @doc """
  Edits a file by applying a list of changes.

  ## Parameters
  - `path`: Path to the file to edit
  - `changes`: List of change structs (see `Types`)
  - `opts`: Options
    - `:validate` - Validate changes before applying (default: true)
    - `:create_backup` - Create backup before editing (default: true)
    - `:format` - Format code after editing (default: false)
    - `:validator` - Custom validator module (optional)
    - `:language` - Explicit language for validation (optional, auto-detected from file extension)

  ## Validation

  When validation is enabled (default), the validator is automatically selected based on file extension.
  Supports: Elixir (.ex, .exs), Erlang (.erl, .hrl), Python (.py), JavaScript (.js, .jsx, .ts, .tsx, .mjs, .cjs)

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> changes = [Types.replace(10, 15, "new content")]
      iex> Core.edit_file("lib/my_file.ex", changes)
      {:ok, %{path: "lib/my_file.ex", changes_applied: 1, ...}}
      
      iex> # Disable validation
      iex> Core.edit_file("lib/file.ex", changes, validate: false)
      {:ok, %{...}}
  """
  @spec edit_file(String.t(), [Types.change()], keyword()) ::
          {:ok, Types.edit_result()} | {:error, term()}
  def edit_file(path, changes, opts \\ []) do
    validate_opt = Keyword.get(opts, :validate, true)
    create_backup_opt = Keyword.get(opts, :create_backup, true)
    format_opt = Keyword.get(opts, :format, false)

    with :ok <- validate_changes_list(changes),
         {:ok, abs_path} <- expand_path(path),
         {:ok, original_content} <- File.read(abs_path),
         {:ok, original_stat} <- File.stat(abs_path),
         {:ok, backup_info} <- maybe_create_backup(abs_path, create_backup_opt),
         {:ok, modified_content} <- apply_changes(original_content, changes),
         :ok <- maybe_validate(modified_content, abs_path, validate_opt, opts),
         :ok <- atomic_write(abs_path, modified_content, original_stat),
         :ok <- maybe_format(abs_path, format_opt, opts) do
      result =
        Types.edit_result(abs_path,
          backup_id: backup_info && backup_info.id,
          changes_applied: length(changes),
          lines_changed: count_lines_changed(changes),
          validation_performed: validate_opt
        )

      Logger.info("Successfully edited #{abs_path} (#{length(changes)} changes)")
      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.error("Failed to edit #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Validates changes without applying them.

  ## Parameters
  - `path`: Path to the file (for context and validator auto-detection)
  - `changes`: List of change structs
  - `opts`: Options
    - `:validator` - Custom validator module (optional)
    - `:language` - Explicit language for validation (optional)

  ## Returns
  - `:ok` if valid
  - `{:error, errors}` if invalid
  """
  @spec validate_changes(String.t(), [Types.change()], keyword()) ::
          :ok | {:error, [Types.validation_error()]}
  def validate_changes(path, changes, opts \\ []) do
    with :ok <- validate_changes_list(changes),
         {:ok, abs_path} <- expand_path(path),
         {:ok, original_content} <- File.read(abs_path),
         {:ok, modified_content} <- apply_changes(original_content, changes) do
      maybe_validate(modified_content, abs_path, true, opts)
    end
  end

  @doc """
  Rolls back the most recent edit to a file.

  ## Parameters
  - `path`: Path to the file
  - `opts`: Options
    - `:backup_id` - Specific backup to restore (optional)

  ## Returns
  - `{:ok, backup_info}` on success
  - `{:error, reason}` on failure
  """
  @spec rollback(String.t(), keyword()) :: {:ok, Types.backup_info()} | {:error, term()}
  def rollback(path, opts \\ []) do
    backup_id = Keyword.get(opts, :backup_id)
    Backup.restore(path, backup_id, opts)
  end

  @doc """
  Gets editing history (backups) for a file.

  ## Parameters
  - `path`: Path to the file
  - `opts`: Options passed to `Backup.list/2`

  ## Returns
  List of backup info structs.
  """
  @spec history(String.t(), keyword()) :: {:ok, [Types.backup_info()]} | {:error, term()}
  def history(path, opts \\ []) do
    Backup.list(path, opts)
  end

  # Private functions

  defp validate_changes_list(changes) when is_list(changes) do
    Enum.reduce_while(changes, :ok, fn change, _acc ->
      case Types.validate_change(change) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "Invalid change: #{reason}"}}
      end
    end)
  end

  defp validate_changes_list(_), do: {:error, "Changes must be a list"}

  defp expand_path(path) do
    {:ok, Path.expand(path)}
  end

  defp maybe_create_backup(_path, false), do: {:ok, nil}

  defp maybe_create_backup(path, true) do
    compress =
      Application.get_env(:ragex, :editor, [])
      |> Keyword.get(:compress_backups, false)

    Backup.create(path, compress: compress)
  end

  defp apply_changes(content, changes) do
    lines = String.split(content, "\n")

    # Sort changes by line number (descending) to avoid index shifting
    sorted_changes = Enum.sort_by(changes, & &1.line_start, :desc)

    case apply_changes_to_lines(lines, sorted_changes) do
      {:ok, modified_lines} ->
        {:ok, Enum.join(modified_lines, "\n")}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_changes_to_lines(lines, changes) do
    Enum.reduce_while(changes, {:ok, lines}, fn change, {:ok, current_lines} ->
      case apply_single_change(current_lines, change) do
        {:ok, new_lines} -> {:cont, {:ok, new_lines}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_single_change(lines, %{
         type: :replace,
         line_start: start,
         line_end: end_line,
         content: content
       }) do
    total_lines = length(lines)

    cond do
      start < 1 or start > total_lines ->
        {:error, "Line #{start} out of range (1-#{total_lines})"}

      end_line < start or end_line > total_lines ->
        {:error, "Line range #{start}-#{end_line} invalid"}

      true ->
        # Replace lines (1-indexed)
        before = Enum.take(lines, start - 1)
        after_lines = Enum.drop(lines, end_line)
        new_content_lines = String.split(content, "\n")

        {:ok, before ++ new_content_lines ++ after_lines}
    end
  end

  defp apply_single_change(lines, %{type: :insert, line_start: start, content: content}) do
    total_lines = length(lines)

    if start < 1 or start > total_lines + 1 do
      {:error, "Insert position #{start} out of range (1-#{total_lines + 1})"}
    else
      # Insert before line (1-indexed)
      before = Enum.take(lines, start - 1)
      after_lines = Enum.drop(lines, start - 1)
      new_content_lines = String.split(content, "\n")

      {:ok, before ++ new_content_lines ++ after_lines}
    end
  end

  defp apply_single_change(lines, %{type: :delete, line_start: start, line_end: end_line}) do
    total_lines = length(lines)

    cond do
      start < 1 or start > total_lines ->
        {:error, "Line #{start} out of range (1-#{total_lines})"}

      end_line < start or end_line > total_lines ->
        {:error, "Line range #{start}-#{end_line} invalid"}

      true ->
        # Delete lines (1-indexed)
        before = Enum.take(lines, start - 1)
        after_lines = Enum.drop(lines, end_line)

        {:ok, before ++ after_lines}
    end
  end

  defp maybe_validate(_content, _path, false, _opts), do: :ok

  defp maybe_validate(content, path, true, opts) do
    # Build validation options
    validator_opts =
      opts
      |> Keyword.put(:path, path)
      |> Keyword.take([:path, :language, :validator])

    case Validator.validate(content, validator_opts) do
      {:ok, :valid} ->
        :ok

      {:ok, :no_validator} ->
        Logger.debug("No validator available for #{path}, skipping validation")
        :ok

      {:error, errors} ->
        {:error, %{type: :validation_error, errors: errors}}
    end
  end

  defp atomic_write(path, content, original_stat) do
    temp_path = "#{path}.ragex_tmp_#{:rand.uniform(999_999)}"

    with :ok <- File.write(temp_path, content),
         :ok <- check_concurrent_modification(path, original_stat),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        # Clean up temp file if it exists
        File.rm(temp_path)
        error
    end
  end

  defp check_concurrent_modification(path, original_stat) do
    case File.stat(path) do
      {:ok, current_stat} ->
        if current_stat.mtime == original_stat.mtime do
          :ok
        else
          {:error, :concurrent_modification}
        end

      {:error, :enoent} ->
        # File was deleted
        {:error, :file_deleted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp count_lines_changed(changes) do
    Enum.reduce(changes, 0, fn change, acc ->
      case change.type do
        :replace ->
          acc + (change.line_end - change.line_start + 1)

        :insert ->
          acc + content_line_count(change.content)

        :delete ->
          acc + (change.line_end - change.line_start + 1)
      end
    end)
  end

  defp content_line_count(nil), do: 0
  defp content_line_count(content), do: length(String.split(content, "\n"))

  defp maybe_format(_path, false, _opts), do: :ok

  defp maybe_format(path, true, opts) do
    format_opts = Keyword.take(opts, [:language, :formatter])

    case Formatter.format(path, format_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        # Format errors are logged but don't fail the edit
        Logger.warning("Format failed for #{path}: #{inspect(reason)}")
        :ok
    end
  end
end
