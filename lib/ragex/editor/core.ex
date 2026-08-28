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
         {:ok, modified_content} <-
           apply_changes_and_validate(original_content, changes, abs_path, validate_opt, opts),
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
         {:ok, _modified_content} <-
           apply_changes_and_validate(original_content, changes, abs_path, true, opts) do
      :ok
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

    case validate_no_overlapping_changes(changes) do
      :ok ->
        # Sort changes by line number (descending) to avoid index shifting
        sorted_changes = Enum.sort_by(changes, & &1.line_start, :desc)

        case apply_changes_to_lines(lines, sorted_changes) do
          {:ok, modified_lines} ->
            {:ok, Enum.join(modified_lines, "\n")}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_no_overlapping_changes(changes) when length(changes) <= 1, do: :ok

  defp validate_no_overlapping_changes(changes) do
    sorted = Enum.sort_by(changes, & &1.line_start)

    overlapping =
      sorted
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [c1, c2] ->
        c1_end = change_end_line(c1)
        c2.line_start <= c1_end
      end)

    if overlapping do
      {:error, "Multiple changes in a single edit request must not have overlapping line ranges"}
    else
      :ok
    end
  end

  defp change_end_line(%{line_end: end_line}) when is_integer(end_line), do: end_line
  defp change_end_line(%{line_start: start}), do: start

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
        new_content_lines = split_content_lines(content)

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
      new_content_lines = split_content_lines(content)

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

  defp split_content_lines(nil), do: [""]

  defp split_content_lines(content) when is_binary(content) do
    # Strip a single trailing newline if present to prevent introducing unintended empty lines
    normalized =
      cond do
        String.ends_with?(content, "\r\n") -> String.slice(content, 0..-3//1)
        String.ends_with?(content, "\n") -> String.slice(content, 0..-2//1)
        true -> content
      end

    String.split(normalized, ~r/\r?\n/)
  end

  defp apply_changes_and_validate(original_content, changes, path, validate_opt, opts) do
    lines = String.split(original_content, "\n")
    resolved_changes = Enum.map(changes, &resolve_change_boundaries(lines, &1))

    with :ok <- validate_no_overlapping_changes(resolved_changes),
         {:ok, modified_content} <- apply_changes(original_content, resolved_changes) do
      maybe_validate_with_autocorrect(
        original_content,
        resolved_changes,
        modified_content,
        path,
        validate_opt,
        opts
      )
    end
  end

  defp resolve_change_boundaries(lines, change) do
    start = change.line_start
    end_line = change[:line_end] || start
    old_content = Map.get(change, :old_content)

    if is_binary(old_content) and old_content != "" do
      case locate_old_content(lines, start, end_line, old_content) do
        {:ok, new_start, new_end} ->
          Map.merge(change, %{line_start: new_start, line_end: new_end})

        :not_found ->
          change
      end
    else
      change
    end
  end

  defp locate_old_content(lines, start, end_line, old_content) do
    target_lines = String.split(normalize_newlines(old_content), "\n")
    target_len = length(target_lines)
    total_lines = length(lines)

    # 1. Check exact or trimmed match at specified position
    if start >= 1 and end_line <= total_lines and end_line - start + 1 == target_len do
      slice = Enum.slice(lines, (start - 1)..(end_line - 1))

      if slice == target_lines or trim_lines(slice) == trim_lines(target_lines) do
        {:ok, start, end_line}
      else
        find_best_match(lines, start, target_lines)
      end
    else
      find_best_match(lines, start, target_lines)
    end
  end

  defp find_best_match(lines, start, target_lines) do
    target_len = length(target_lines)
    total_lines = length(lines)

    if target_len > total_lines do
      :not_found
    else
      candidates =
        0..(total_lines - target_len)
        |> Enum.map(fn idx ->
          slice = Enum.slice(lines, idx..(idx + target_len - 1))
          start_line = idx + 1
          end_line = start_line + target_len - 1
          dist = abs(start_line - start)

          cond do
            slice == target_lines -> {0, dist, start_line, end_line}
            trim_lines(slice) == trim_lines(target_lines) -> {1, dist, start_line, end_line}
            true -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      case Enum.sort_by(candidates, fn {quality, dist, _, _} -> {quality, dist} end) do
        [{_quality, _dist, best_start, best_end} | _] ->
          Logger.info(
            "Re-aligned change line boundaries to #{best_start}-#{best_end} based on old_content match"
          )

          {:ok, best_start, best_end}

        [] ->
          :not_found
      end
    end
  end

  defp normalize_newlines(str) do
    str
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp trim_lines(lines_list) do
    Enum.map(lines_list, &String.trim/1)
  end

  defp maybe_validate_with_autocorrect(
         _orig_content,
         _changes,
         modified_content,
         _path,
         false,
         _opts
       ) do
    {:ok, modified_content}
  end

  defp maybe_validate_with_autocorrect(
         orig_content,
         changes,
         modified_content,
         path,
         true,
         opts
       ) do
    validator_opts =
      opts
      |> Keyword.put(:path, path)
      |> Keyword.take([:path, :language, :validator])

    case Validator.validate(modified_content, validator_opts) do
      {:ok, :valid} ->
        {:ok, modified_content}

      {:ok, :no_validator} ->
        Logger.debug("No validator available for #{path}, skipping validation")
        {:ok, modified_content}

      {:error, errors} ->
        auto_correct_opt = Keyword.get(opts, :auto_correct, true)

        if auto_correct_opt do
          case try_autocorrect_boundaries(orig_content, changes, validator_opts) do
            {:ok, corrected_content} ->
              Logger.info("Auto-corrected change boundaries to pass validation for #{path}")
              {:ok, corrected_content}

            :failed ->
              hint = build_enhanced_hint(errors, changes, orig_content)
              {:error, %{type: :validation_error, errors: errors, hint: hint}}
          end
        else
          hint = build_enhanced_hint(errors, changes, orig_content)
          {:error, %{type: :validation_error, errors: errors, hint: hint}}
        end
    end
  end

  defp try_autocorrect_boundaries(orig_content, changes, validator_opts) do
    lines = String.split(orig_content, "\n")
    total_lines = length(lines)

    shifts = [-1, 1, -2, 2, -3, 3]

    Enum.reduce_while(shifts, :failed, fn delta, _acc ->
      candidate_changes =
        Enum.map(changes, fn change ->
          s = change.line_start
          e = change.line_end || s
          span = e - s
          new_s = s + delta
          new_e = new_s + span
          Map.merge(change, %{line_start: new_s, line_end: new_e})
        end)

      all_valid_bounds =
        Enum.all?(candidate_changes, fn c ->
          c.line_start >= 1 and c.line_end <= total_lines
        end)

      if all_valid_bounds do
        case validate_no_overlapping_changes(candidate_changes) do
          :ok ->
            case apply_changes(orig_content, candidate_changes) do
              {:ok, cand_content} ->
                case Validator.validate(cand_content, validator_opts) do
                  {:ok, :valid} -> {:halt, {:ok, cand_content}}
                  _ -> {:cont, :failed}
                end

              _ ->
                {:cont, :failed}
            end

          _ ->
            {:cont, :failed}
        end
      else
        {:cont, :failed}
      end
    end)
  end

  defp build_enhanced_hint(errors, changes, orig_content) do
    orig_lines = String.split(orig_content, "\n")
    total_lines = length(orig_lines)

    change_info =
      Enum.map(changes, fn c ->
        s = c.line_start
        e = c.line_end || s
        "lines #{s}-#{e}"
      end)
      |> Enum.join(", ")

    error_summary =
      Enum.map(errors, fn err ->
        line_info = if err.line, do: "line #{err.line}", else: "unknown line"
        "#{line_info}: #{err.message}"
      end)
      |> Enum.join("; ")

    first_change = List.first(changes)

    snippet_hint =
      if first_change do
        s = max(1, first_change.line_start - 2)
        e = min(total_lines, (first_change.line_end || first_change.line_start) + 2)

        context_lines =
          s..e
          |> Enum.map(fn idx ->
            line_text = Enum.at(orig_lines, idx - 1) || ""
            "#{idx}: #{line_text}"
          end)
          |> Enum.join("\n")

        "\nOriginal file context around target (#{s}-#{e}):\n#{context_lines}"
      else
        ""
      end

    "Syntax error after applying change to #{change_info} (#{error_summary}). This indicates line_start or line_end was off by a few lines, clipping or duplicating block keywords (e.g., 'def', 'do', 'end') or syntax constructs. Verify line numbers against original file context.#{snippet_hint}"
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
