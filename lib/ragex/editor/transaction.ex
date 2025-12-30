defmodule Ragex.Editor.Transaction do
  @moduledoc """
  Multi-file atomic edit transactions.

  Provides transaction-like semantics for editing multiple files:
  - All-or-nothing atomicity
  - Coordinated backups across files
  - Validation of all files before committing
  - Automatic rollback on any failure
  """

  alias Ragex.Editor.{Core, Types}
  require Logger

  @typedoc """
  A transaction containing multiple file edits.
  """
  @type t :: %__MODULE__{
          edits: [file_edit()],
          opts: keyword()
        }

  @typedoc """
  A single file edit within a transaction.
  """
  @type file_edit :: %{
          path: String.t(),
          changes: [Types.change()],
          opts: keyword()
        }

  @typedoc """
  Result of a transaction commit.
  """
  @type transaction_result :: %{
          status: :success | :failure,
          files_edited: non_neg_integer(),
          results: [Types.edit_result()],
          errors: [term()],
          rolled_back: boolean()
        }

  defstruct edits: [], opts: []

  @doc """
  Creates a new empty transaction.

  ## Examples

      iex> Transaction.new()
      %Transaction{edits: [], opts: []}
      
      iex> Transaction.new(validate: false)
      %Transaction{edits: [], opts: [validate: false]}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{edits: [], opts: opts}
  end

  @doc """
  Adds a file edit to the transaction.

  ## Parameters
  - `transaction`: The transaction to add to
  - `path`: Path to the file
  - `changes`: List of changes to apply
  - `opts`: Per-file options (override transaction defaults)

  ## Examples

      iex> txn = Transaction.new()
      iex> txn = Transaction.add(txn, "lib/file1.ex", [Types.replace(1, 1, "new")])
      iex> txn = Transaction.add(txn, "lib/file2.ex", [Types.replace(2, 2, "new")])
  """
  @spec add(t(), String.t(), [Types.change()], keyword()) :: t()
  def add(transaction, path, changes, opts \\ []) do
    edit = %{
      path: path,
      changes: changes,
      opts: opts
    }

    %{transaction | edits: transaction.edits ++ [edit]}
  end

  @doc """
  Validates all edits in the transaction without applying them.

  Returns {:ok, :valid} if all edits are valid, or {:error, errors} with
  details about which files failed validation.

  ## Examples

      iex> txn = Transaction.new() |> Transaction.add("lib/file.ex", changes)
      iex> Transaction.validate(txn)
      {:ok, :valid}
  """
  @spec validate(t()) :: {:ok, :valid} | {:error, [{String.t(), term()}]}
  def validate(transaction) do
    results =
      Enum.reduce_while(transaction.edits, [], fn edit, acc ->
        opts = Keyword.merge(transaction.opts, edit.opts)

        case Core.validate_changes(edit.path, edit.changes, opts) do
          :ok ->
            {:cont, acc}

          {:error, errors} ->
            {:halt, [{edit.path, errors} | acc]}
        end
      end)

    case results do
      [] -> {:ok, :valid}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Commits the transaction, applying all edits atomically.

  If any edit fails (including validation), all changes are rolled back
  and the transaction returns an error.

  ## Process
  1. Validate all edits
  2. Create backups for all files
  3. Apply all edits
  4. If any step fails, rollback all changes

  ## Returns
  - `{:ok, result}` if all edits succeeded
  - `{:error, result}` if any edit failed (includes rollback status)

  ## Examples

      iex> txn = Transaction.new()
      iex>   |> Transaction.add("lib/file1.ex", changes1)
      iex>   |> Transaction.add("lib/file2.ex", changes2)
      iex> Transaction.commit(txn)
      {:ok, %{status: :success, files_edited: 2, ...}}
  """
  @spec commit(t()) :: {:ok, transaction_result()} | {:error, transaction_result()}
  def commit(transaction) do
    Logger.info("Starting transaction with #{length(transaction.edits)} edits")

    # Phase 1: Validate all edits (if validation is enabled)
    should_validate = Keyword.get(transaction.opts, :validate, true)

    validation_result =
      if should_validate do
        validate(transaction)
      else
        {:ok, :valid}
      end

    case validation_result do
      {:ok, :valid} ->
        # Phase 2: Apply all edits
        apply_all_edits(transaction)

      {:error, validation_errors} ->
        Logger.error("Transaction validation failed for #{length(validation_errors)} files")

        result = %{
          status: :failure,
          files_edited: 0,
          results: [],
          errors: validation_errors,
          rolled_back: false
        }

        {:error, result}
    end
  end

  # Private functions

  defp apply_all_edits(transaction) do
    # Apply each edit, collecting results
    {status, results, errors} =
      Enum.reduce_while(transaction.edits, {:ok, [], []}, fn edit,
                                                             {_status, results_acc, errors_acc} ->
        opts = Keyword.merge(transaction.opts, edit.opts)

        case Core.edit_file(edit.path, edit.changes, opts) do
          {:ok, result} ->
            {:cont, {:ok, [result | results_acc], errors_acc}}

          {:error, reason} ->
            error = {edit.path, reason}
            # Stop on first error
            {:halt, {:error, results_acc, [error | errors_acc]}}
        end
      end)

    case status do
      :ok ->
        # All edits succeeded
        result = %{
          status: :success,
          files_edited: length(results),
          results: Enum.reverse(results),
          errors: [],
          rolled_back: false
        }

        Logger.info("Transaction committed successfully (#{length(results)} files)")
        {:ok, result}

      :error ->
        # At least one edit failed - rollback all
        Logger.error("Transaction failed, rolling back #{length(results)} files")
        rolled_back = rollback_edits(Enum.reverse(results))

        result = %{
          status: :failure,
          files_edited: length(results),
          results: Enum.reverse(results),
          errors: Enum.reverse(errors),
          rolled_back: rolled_back
        }

        {:error, result}
    end
  end

  defp rollback_edits(results) do
    # Attempt to rollback each successfully edited file
    rollback_results =
      Enum.map(results, fn result ->
        case Core.rollback(result.path, backup_id: result.backup_id) do
          {:ok, _backup_info} ->
            Logger.info("Rolled back #{result.path}")
            :ok

          {:error, reason} ->
            Logger.error("Failed to rollback #{result.path}: #{inspect(reason)}")
            {:error, reason}
        end
      end)

    # Return true if all rollbacks succeeded
    Enum.all?(rollback_results, &(&1 == :ok))
  end
end
