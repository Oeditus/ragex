defmodule Ragex.Editor.Types do
  @moduledoc """
  Common types and structs for the editor module.

  Defines data structures for changes, backups, and operation results.
  """

  @typedoc """
  Type of edit operation.
  """
  @type change_type :: :replace | :insert | :delete

  @typedoc """
  A single change to apply to a file.
  """
  @type change :: %{
          type: change_type(),
          line_start: pos_integer(),
          line_end: pos_integer() | nil,
          content: String.t() | nil
        }

  @typedoc """
  Result of an edit operation.
  """
  @type edit_result :: %{
          path: String.t(),
          backup_id: String.t() | nil,
          changes_applied: non_neg_integer(),
          lines_changed: non_neg_integer(),
          validation_performed: boolean(),
          timestamp: DateTime.t()
        }

  @typedoc """
  Information about a backup.
  """
  @type backup_info :: %{
          id: String.t(),
          path: String.t(),
          backup_path: String.t(),
          size: non_neg_integer(),
          created_at: DateTime.t(),
          original_mtime: integer()
        }

  @typedoc """
  Validation error.
  """
  @type validation_error :: %{
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          message: String.t(),
          severity: :error | :warning
        }

  @doc """
  Creates a replace change struct.

  ## Examples

      iex> Types.replace(10, 15, "new content")
      %{type: :replace, line_start: 10, line_end: 15, content: "new content"}
  """
  @spec replace(pos_integer(), pos_integer(), String.t()) :: change()
  def replace(line_start, line_end, content) do
    %{
      type: :replace,
      line_start: line_start,
      line_end: line_end,
      content: content
    }
  end

  @doc """
  Creates an insert change struct.

  ## Examples

      iex> Types.insert(20, "inserted line")
      %{type: :insert, line_start: 20, line_end: nil, content: "inserted line"}
  """
  @spec insert(pos_integer(), String.t()) :: change()
  def insert(line_start, content) do
    %{
      type: :insert,
      line_start: line_start,
      line_end: nil,
      content: content
    }
  end

  @doc """
  Creates a delete change struct.

  ## Examples

      iex> Types.delete(5, 8)
      %{type: :delete, line_start: 5, line_end: 8, content: nil}
  """
  @spec delete(pos_integer(), pos_integer()) :: change()
  def delete(line_start, line_end) do
    %{
      type: :delete,
      line_start: line_start,
      line_end: line_end,
      content: nil
    }
  end

  @doc """
  Validates a change struct.

  Returns `:ok` if valid, `{:error, reason}` otherwise.
  """
  @spec validate_change(change()) :: :ok | {:error, String.t()}
  def validate_change(%{type: type, line_start: line_start} = change)
      when type in [:replace, :insert, :delete] and is_integer(line_start) and line_start > 0 do
    case type do
      :replace ->
        if is_integer(change.line_end) and change.line_end >= line_start and
             is_binary(change.content) do
          :ok
        else
          {:error, "Replace requires line_end >= line_start and content"}
        end

      :insert ->
        if is_binary(change.content) do
          :ok
        else
          {:error, "Insert requires content"}
        end

      :delete ->
        if is_integer(change.line_end) and change.line_end >= line_start do
          :ok
        else
          {:error, "Delete requires line_end >= line_start"}
        end
    end
  end

  def validate_change(_), do: {:error, "Invalid change structure"}

  @doc """
  Creates an edit result struct.
  """
  @spec edit_result(String.t(), keyword()) :: edit_result()
  def edit_result(path, opts \\ []) do
    %{
      path: path,
      backup_id: Keyword.get(opts, :backup_id),
      changes_applied: Keyword.get(opts, :changes_applied, 0),
      lines_changed: Keyword.get(opts, :lines_changed, 0),
      validation_performed: Keyword.get(opts, :validation_performed, false),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Creates a backup info struct.
  """
  @spec backup_info(String.t(), String.t(), String.t(), keyword()) :: backup_info()
  def backup_info(id, path, backup_path, opts \\ []) do
    %{
      id: id,
      path: path,
      backup_path: backup_path,
      size: Keyword.get(opts, :size, 0),
      created_at: Keyword.get(opts, :created_at, DateTime.utc_now()),
      original_mtime: Keyword.get(opts, :original_mtime, 0)
    }
  end

  @doc """
  Creates a validation error struct.
  """
  @spec validation_error(String.t(), keyword()) :: validation_error()
  def validation_error(message, opts \\ []) do
    %{
      line: Keyword.get(opts, :line),
      column: Keyword.get(opts, :column),
      message: message,
      severity: Keyword.get(opts, :severity, :error)
    }
  end
end
