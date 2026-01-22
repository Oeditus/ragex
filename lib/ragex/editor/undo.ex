defmodule Ragex.Editor.Undo do
  @moduledoc """
  Multi-level undo/redo stack for refactoring operations.

  Provides persistent history of refactoring operations with the ability
  to undo and redo changes. History is stored per-project in:
  `~/.ragex/undo/<project_hash>/`

  Each undo entry contains:
  - Operation metadata (type, timestamp, parameters)
  - File states before the operation
  - Operation result (success/failure)
  """

  require Logger

  @type operation_type ::
          :rename_function
          | :rename_module
          | :extract_function
          | :inline_function
          | :convert_visibility
          | :rename_parameter
          | :modify_attributes
          | :change_signature
          | :move_function
          | :extract_module

  @type undo_entry :: %{
          id: String.t(),
          operation: operation_type(),
          timestamp: DateTime.t(),
          params: map(),
          files_affected: [String.t()],
          file_states: %{String.t() => String.t()},
          result: :success | :failure,
          description: String.t()
        }

  @type undo_stack :: [undo_entry()]

  @doc """
  Pushes a new operation onto the undo stack.

  ## Parameters
  - `project_path`: Project root path
  - `operation`: Operation type atom
  - `params`: Operation parameters
  - `files_affected`: List of file paths
  - `result`: Operation result

  ## Returns
  - `{:ok, entry_id}` on success
  - `{:error, reason}` on failure
  """
  @spec push_undo(String.t(), operation_type(), map(), [String.t()], :success | :failure) ::
          {:ok, String.t()} | {:error, term()}
  def push_undo(project_path, operation, params, files_affected, result) do
    with {:ok, project_hash} <- get_project_hash(project_path),
         {:ok, stack_dir} <- ensure_stack_dir(project_hash),
         {:ok, file_states} <- capture_file_states(files_affected) do
      entry = %{
        id: generate_id(),
        operation: operation,
        timestamp: DateTime.utc_now(),
        params: params,
        files_affected: files_affected,
        file_states: file_states,
        result: result,
        description: describe_operation(operation, params)
      }

      entry_file = Path.join(stack_dir, "#{entry.id}.etf")

      case File.write(entry_file, :erlang.term_to_binary(entry)) do
        :ok ->
          Logger.info("Undo entry created: #{entry.id}")
          {:ok, entry.id}

        {:error, reason} ->
          {:error, "Failed to write undo entry: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Undoes the most recent operation.

  ## Parameters
  - `project_path`: Project root path

  ## Returns
  - `{:ok, result}` with undo details on success
  - `{:error, reason}` on failure
  """
  @spec undo(String.t()) :: {:ok, map()} | {:error, term()}
  def undo(project_path) do
    with {:ok, project_hash} <- get_project_hash(project_path),
         {:ok, entries} <- load_stack_entries(project_hash),
         {:ok, entry} <- get_latest_entry(entries) do
      # Restore files to their pre-operation state
      restore_results =
        Enum.map(entry.file_states, fn {path, content} ->
          case File.write(path, content) do
            :ok -> {:ok, path}
            {:error, reason} -> {:error, {path, reason}}
          end
        end)

      errors = Enum.filter(restore_results, &match?({:error, _}, &1))

      if Enum.empty?(errors) do
        # Mark entry as undone
        mark_entry_undone(project_hash, entry.id)

        Logger.info("Undid operation: #{entry.description}")

        {:ok,
         %{
           operation: entry.operation,
           description: entry.description,
           files_restored: map_size(entry.file_states)
         }}
      else
        {:error, "Failed to restore some files: #{inspect(errors)}"}
      end
    end
  end

  @doc """
  Redoes the most recently undone operation.

  ## Parameters
  - `project_path`: Project root path

  ## Returns
  - `{:ok, result}` with redo details on success
  - `{:error, reason}` on failure
  """
  @spec redo(String.t()) :: {:ok, map()} | {:error, term()}
  def redo(project_path) do
    with {:ok, project_hash} <- get_project_hash(project_path),
         {:ok, entry} <- get_latest_undone(project_hash) do
      # Re-apply the operation by calling the original refactoring function
      # For now, we return info suggesting manual re-application
      {:ok,
       %{
         operation: entry.operation,
         description: entry.description,
         message: "Re-apply operation manually using: #{entry.description}"
       }}
    end
  end

  @doc """
  Lists the undo history for a project.

  ## Parameters
  - `project_path`: Project root path
  - `opts`: Options
    - `:limit` - Maximum entries to return (default: 50)
    - `:include_undone` - Include undone entries (default: false)

  ## Returns
  - `{:ok, entries}` list of undo entries
  """
  @spec list_undo_stack(String.t(), keyword()) :: {:ok, [undo_entry()]} | {:error, term()}
  def list_undo_stack(project_path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    include_undone = Keyword.get(opts, :include_undone, false)

    with {:ok, project_hash} <- get_project_hash(project_path),
         {:ok, entries} <- load_stack_entries(project_hash) do
      filtered =
        entries
        |> maybe_filter_undone(include_undone)
        |> Enum.take(limit)

      {:ok, filtered}
    end
  end

  @doc """
  Clears the undo history for a project.

  ## Parameters
  - `project_path`: Project root path
  - `opts`: Options
    - `:keep_last` - Number of entries to keep (default: 0)

  ## Returns
  - `{:ok, count}` number of entries cleared
  """
  @spec clear_undo_stack(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def clear_undo_stack(project_path, opts \\ []) do
    keep_last = Keyword.get(opts, :keep_last, 0)

    with {:ok, project_hash} <- get_project_hash(project_path),
         {:ok, stack_dir} <- get_stack_dir(project_hash),
         {:ok, entries} <- load_stack_entries(project_hash) do
      to_delete = Enum.drop(Enum.reverse(entries), keep_last)

      deleted =
        Enum.reduce(to_delete, 0, fn entry, count ->
          entry_file = Path.join(stack_dir, "#{entry.id}.etf")

          case File.rm(entry_file) do
            :ok -> count + 1
            {:error, _} -> count
          end
        end)

      {:ok, deleted}
    end
  end

  # Private functions

  defp get_project_hash(project_path) do
    hash =
      :crypto.hash(:sha256, project_path) |> Base.encode16(case: :lower) |> String.slice(0, 16)

    {:ok, hash}
  end

  defp ensure_stack_dir(project_hash) do
    base_dir = Path.join([System.user_home!(), ".ragex", "undo", project_hash])

    case File.mkdir_p(base_dir) do
      :ok -> {:ok, base_dir}
      {:error, reason} -> {:error, "Failed to create undo directory: #{inspect(reason)}"}
    end
  end

  defp get_stack_dir(project_hash) do
    dir = Path.join([System.user_home!(), ".ragex", "undo", project_hash])

    if File.exists?(dir) do
      {:ok, dir}
    else
      {:error, :no_undo_history}
    end
  end

  defp capture_file_states(file_paths) do
    states =
      Enum.reduce_while(file_paths, %{}, fn path, acc ->
        case File.read(path) do
          {:ok, content} -> {:cont, Map.put(acc, path, content)}
          {:error, reason} -> {:halt, {:error, {path, reason}}}
        end
      end)

    case states do
      {:error, _} = error -> error
      states when is_map(states) -> {:ok, states}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp describe_operation(operation, params) do
    case operation do
      :rename_function ->
        "Rename #{params[:module]}.#{params[:old_name]}/#{params[:arity]} to #{params[:new_name]}"

      :rename_module ->
        "Rename module #{params[:old_name]} to #{params[:new_name]}"

      :extract_function ->
        "Extract #{params[:new_function]} from #{params[:module]}.#{params[:source_function]}"

      :inline_function ->
        "Inline #{params[:module]}.#{params[:function]}/#{params[:arity]}"

      :convert_visibility ->
        "Convert #{params[:module]}.#{params[:function]}/#{params[:arity]} to #{params[:visibility]}"

      :rename_parameter ->
        "Rename parameter #{params[:old_param]} to #{params[:new_param]} in #{params[:module]}.#{params[:function]}"

      :modify_attributes ->
        "Modify #{length(params[:changes])} attribute(s) in #{params[:module]}"

      :change_signature ->
        "Change signature of #{params[:module]}.#{params[:function]} (#{length(params[:changes])} change(s))"

      :move_function ->
        "Move #{params[:function]}/#{params[:arity]} from #{params[:source_module]} to #{params[:target_module]}"

      :extract_module ->
        "Extract #{length(params[:functions])} function(s) from #{params[:source_module]} to #{params[:new_module]}"

      _ ->
        "#{operation}"
    end
  end

  defp load_stack_entries(project_hash) do
    with {:ok, stack_dir} <- get_stack_dir(project_hash) do
      entries =
        File.ls!(stack_dir)
        |> Enum.filter(&String.ends_with?(&1, ".etf"))
        |> Enum.map(fn file ->
          path = Path.join(stack_dir, file)
          {:ok, binary} = File.read(path)
          :erlang.binary_to_term(binary)
        end)
        |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

      {:ok, entries}
    end
  rescue
    _ -> {:ok, []}
  end

  defp get_latest_entry([]), do: {:error, :no_undo_history}

  defp get_latest_entry([entry | _] = _entries) do
    if Map.get(entry, :undone, false) do
      {:error, :already_undone}
    else
      {:ok, entry}
    end
  end

  defp mark_entry_undone(project_hash, entry_id) do
    with {:ok, stack_dir} <- get_stack_dir(project_hash) do
      entry_file = Path.join(stack_dir, "#{entry_id}.etf")

      case File.read(entry_file) do
        {:ok, binary} ->
          entry = :erlang.binary_to_term(binary)
          updated_entry = Map.put(entry, :undone, true)
          File.write(entry_file, :erlang.term_to_binary(updated_entry))

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_latest_undone(project_hash) do
    with {:ok, entries} <- load_stack_entries(project_hash) do
      case Enum.find(entries, &Map.get(&1, :undone, false)) do
        nil -> {:error, :no_undone_operations}
        entry -> {:ok, entry}
      end
    end
  end

  defp maybe_filter_undone(entries, true), do: entries

  defp maybe_filter_undone(entries, false) do
    Enum.reject(entries, &Map.get(&1, :undone, false))
  end
end
