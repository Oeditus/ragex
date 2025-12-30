defmodule Ragex.Editor.Refactor do
  @moduledoc """
  Semantic refactoring operations that leverage the knowledge graph.

  Provides AST-aware refactoring operations like rename_function and
  rename_module that automatically update all affected files using
  the graph to find call sites and dependencies.
  """

  alias Ragex.Graph.Store
  alias Ragex.Editor.{Transaction, Types}
  alias Ragex.Editor.Refactor.Elixir, as: ElixirRefactor
  require Logger

  @type refactor_result :: %{
          status: :success | :failure,
          files_modified: non_neg_integer(),
          transaction_result: Transaction.transaction_result()
        }

  @doc """
  Renames a function across the entire codebase.

  Uses the knowledge graph to find all call sites and updates them atomically.

  ## Parameters
  - `module_name`: Module containing the function (atom or string)
  - `old_name`: Current function name (atom or string)
  - `new_name`: New function name (atom or string)
  - `arity`: Function arity
  - `opts`: Options
    - `:validate` - Validate before/after (default: true)
    - `:format` - Format files after editing (default: true)
    - `:scope` - :module (same module only) or :project (all files, default)

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure (with rollback)

  ## Examples

      # Rename MyModule.old_func/2 to MyModule.new_func/2 across project
      Refactor.rename_function(:MyModule, :old_func, :new_func, 2)
      
      # Rename only within the same module
      Refactor.rename_function(:MyModule, :old_func, :new_func, 2, scope: :module)
  """
  @spec rename_function(
          atom() | String.t(),
          atom() | String.t(),
          atom() | String.t(),
          non_neg_integer(),
          keyword()
        ) :: {:ok, refactor_result()} | {:error, term()}
  def rename_function(module_name, old_name, new_name, arity, opts \\ []) do
    module_atom = to_atom(module_name)
    old_atom = to_atom(old_name)
    new_atom = to_atom(new_name)
    scope = Keyword.get(opts, :scope, :project)

    Logger.info(
      "Starting refactor: rename #{module_atom}.#{old_atom}/#{arity} to #{new_atom} (scope: #{scope})"
    )

    with {:ok, affected_files} <- find_affected_files(module_atom, old_atom, arity, scope),
         {:ok, transaction} <-
           build_refactor_transaction(affected_files, old_atom, new_atom, arity, opts),
         result <- Transaction.commit(transaction) do
      case result do
        {:ok, txn_result} ->
          Logger.info("Refactor completed: #{txn_result.files_edited} files modified")

          {:ok,
           %{
             status: :success,
             files_modified: txn_result.files_edited,
             transaction_result: txn_result
           }}

        {:error, txn_result} ->
          Logger.error("Refactor failed: #{inspect(txn_result.errors)}")

          {:error,
           %{
             status: :failure,
             files_modified: txn_result.files_edited,
             rolled_back: txn_result.rolled_back,
             errors: txn_result.errors
           }}
      end
    else
      {:error, reason} = error ->
        Logger.error("Refactor failed during preparation: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Renames a module across the entire codebase.

  Updates the module definition and all references (imports, aliases, calls).

  ## Parameters
  - `old_name`: Current module name (atom or string)
  - `new_name`: New module name (atom or string)
  - `opts`: Options (same as rename_function)

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure (with rollback)

  ## Examples

      Refactor.rename_module(:OldModule, :NewModule)
  """
  @spec rename_module(atom() | String.t(), atom() | String.t(), keyword()) ::
          {:ok, refactor_result()} | {:error, term()}
  def rename_module(old_name, new_name, opts \\ []) do
    old_atom = to_atom(old_name)
    new_atom = to_atom(new_name)

    Logger.info("Starting refactor: rename module #{old_atom} to #{new_atom}")

    with {:ok, affected_files} <- find_module_references(old_atom),
         {:ok, transaction} <-
           build_module_refactor_transaction(affected_files, old_atom, new_atom, opts),
         result <- Transaction.commit(transaction) do
      case result do
        {:ok, txn_result} ->
          Logger.info("Module refactor completed: #{txn_result.files_edited} files modified")

          {:ok,
           %{
             status: :success,
             files_modified: txn_result.files_edited,
             transaction_result: txn_result
           }}

        {:error, txn_result} ->
          Logger.error("Module refactor failed: #{inspect(txn_result.errors)}")

          {:error,
           %{
             status: :failure,
             files_modified: txn_result.files_edited,
             rolled_back: txn_result.rolled_back,
             errors: txn_result.errors
           }}
      end
    end
  end

  # Private functions

  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value) when is_binary(value), do: String.to_atom(value)

  # Find all files affected by renaming a function
  defp find_affected_files(module_name, function_name, arity, scope) do
    function_id = {module_name, function_name, arity}

    # Find the function definition
    case Store.find_node(:function, function_id) do
      nil ->
        {:error, "Function #{module_name}.#{function_name}/#{arity} not found in graph"}

      function_node ->
        definition_file = function_node[:file]

        # Find all callers (incoming edges)
        # get_incoming_edges expects full identifier with type
        full_function_id = {:function, module_name, function_name, arity}
        callers = Store.get_incoming_edges(full_function_id, :calls)

        caller_files =
          callers
          |> Enum.map(fn %{from: {:function, mod, func, ar}} ->
            case Store.find_node(:function, {mod, func, ar}) do
              nil -> nil
              node -> node[:file]
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        # Combine definition file and caller files
        all_files = [definition_file | caller_files] |> Enum.uniq() |> Enum.reject(&is_nil/1)

        # Filter by scope
        files_to_modify =
          case scope do
            :module ->
              # Only files in the same module (same file as definition)
              [definition_file]

            :project ->
              # All affected files
              all_files
          end

        Logger.debug("Found #{length(files_to_modify)} files affected by function rename")
        {:ok, files_to_modify}
    end
  end

  # Find all files that reference a module
  defp find_module_references(module_name) do
    # Find the module node
    case Store.find_node(:module, module_name) do
      nil ->
        {:error, "Module #{module_name} not found in graph"}

      module_node ->
        definition_file = module_node[:file]

        # Find all modules that import this module
        full_module_id = {:module, module_name}
        importers = Store.get_incoming_edges(full_module_id, :imports)

        importer_files =
          importers
          |> Enum.map(fn %{from: {:module, mod}} ->
            case Store.find_node(:module, mod) do
              nil -> nil
              node -> node[:file]
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        all_files = [definition_file | importer_files] |> Enum.uniq() |> Enum.reject(&is_nil/1)

        Logger.debug("Found #{length(all_files)} files affected by module rename")
        {:ok, all_files}
    end
  end

  # Build transaction for function rename
  defp build_refactor_transaction(files, old_name, new_name, arity, opts) do
    validate = Keyword.get(opts, :validate, true)
    format = Keyword.get(opts, :format, true)

    txn = Transaction.new(validate: validate, format: format, create_backup: true)

    # For each file, generate the refactored content
    result =
      Enum.reduce_while(files, {:ok, txn}, fn file_path, {:ok, transaction_acc} ->
        case refactor_file_function(file_path, old_name, new_name, arity) do
          {:ok, changes} ->
            {:cont, {:ok, Transaction.add(transaction_acc, file_path, changes)}}

          {:error, reason} ->
            {:halt, {:error, "Failed to refactor #{file_path}: #{inspect(reason)}"}}
        end
      end)

    case result do
      {:ok, _transaction} = success -> success
      {:error, _reason} = error -> error
    end
  end

  # Build transaction for module rename
  defp build_module_refactor_transaction(files, old_name, new_name, opts) do
    validate = Keyword.get(opts, :validate, true)
    format = Keyword.get(opts, :format, true)

    txn = Transaction.new(validate: validate, format: format, create_backup: true)

    result =
      Enum.reduce_while(files, {:ok, txn}, fn file_path, {:ok, transaction_acc} ->
        case refactor_file_module(file_path, old_name, new_name) do
          {:ok, changes} ->
            {:cont, {:ok, Transaction.add(transaction_acc, file_path, changes)}}

          {:error, reason} ->
            {:halt, {:error, "Failed to refactor #{file_path}: #{inspect(reason)}"}}
        end
      end)

    case result do
      {:ok, _transaction} = success -> success
      {:error, _reason} = error -> error
    end
  end

  # Generate changes for renaming a function in a file
  defp refactor_file_function(file_path, old_name, new_name, arity) do
    language = detect_language(file_path)

    with {:ok, content} <- File.read(file_path),
         {:ok, new_content} <-
           refactor_function_content(content, old_name, new_name, arity, language) do
      # Generate a replace change for the entire file
      lines = String.split(content, "\n")
      line_count = length(lines)

      changes = [Types.replace(1, line_count, new_content)]
      {:ok, changes}
    end
  end

  # Generate changes for renaming a module in a file
  defp refactor_file_module(file_path, old_name, new_name) do
    language = detect_language(file_path)

    with {:ok, content} <- File.read(file_path),
         {:ok, new_content} <- refactor_module_content(content, old_name, new_name, language) do
      lines = String.split(content, "\n")
      line_count = length(lines)

      changes = [Types.replace(1, line_count, new_content)]
      {:ok, changes}
    end
  end

  # Refactor function in content based on language
  defp refactor_function_content(content, old_name, new_name, arity, language) do
    case language do
      :elixir ->
        ElixirRefactor.rename_function(content, old_name, new_name, arity)

      :erlang ->
        # Erlang refactoring not yet implemented
        {:error, "Erlang refactoring not yet implemented"}

      _ ->
        {:error, "Refactoring not supported for language: #{language}"}
    end
  end

  # Refactor module in content based on language
  defp refactor_module_content(content, old_name, new_name, language) do
    case language do
      :elixir ->
        ElixirRefactor.rename_module(content, old_name, new_name)

      :erlang ->
        {:error, "Erlang refactoring not yet implemented"}

      _ ->
        {:error, "Refactoring not supported for language: #{language}"}
    end
  end

  # Detect language from file extension
  defp detect_language(file_path) do
    ext = Path.extname(file_path)

    case ext do
      ext when ext in [".ex", ".exs"] -> :elixir
      ext when ext in [".erl", ".hrl"] -> :erlang
      ext when ext == ".py" -> :python
      ext when ext in [".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"] -> :javascript
      _ -> :unknown
    end
  end
end
