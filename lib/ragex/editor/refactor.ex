defmodule Ragex.Editor.Refactor do
  @moduledoc """
  Semantic refactoring operations that leverage the knowledge graph.

  Provides AST-aware refactoring operations like rename_function and
  rename_module that automatically update all affected files using
  the graph to find call sites and dependencies.
  """

  alias Ragex.Editor.Refactor.Elixir, as: ElixirRefactor
  alias Ragex.Editor.{Transaction, Types, Undo}
  alias Ragex.Graph.Store
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

          # Track undo history if enabled
          if Keyword.get(opts, :track_undo, true) do
            project_path = find_project_root(hd(affected_files))

            params = %{
              module: module_atom,
              old_name: old_atom,
              new_name: new_atom,
              arity: arity,
              scope: scope
            }

            Undo.push_undo(project_path, :rename_function, params, affected_files, :success)
          end

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
  Extracts a range of lines from a function into a new function.

  ## Parameters
  - `module_name`: Module containing the function
  - `source_function`: Function to extract from
  - `source_arity`: Arity of source function
  - `new_function_name`: Name for the extracted function
  - `line_range`: {start_line, end_line} tuple (1-indexed)
  - `opts`: Options
    - `:placement` - :after_source | :before_source | :end_of_module (default: :after_source)
    - `:visibility` - :public | :private (default: :private)
    - `:add_doc` - boolean (default: false)
    - `:validate` - boolean (default: true)
    - `:format` - boolean (default: true)

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure (with rollback)

  ## Examples

      # Extract lines 10-15 from MyModule.process/2 into helper/0
      Refactor.extract_function(:MyModule, :process, 2, :helper, {10, 15})

      # Extract as public function at end of module
      Refactor.extract_function(
        :MyModule, :process, 2, :extracted_logic, {10, 15},
        visibility: :public, placement: :end_of_module
      )
  """
  @spec extract_function(
          atom() | String.t(),
          atom() | String.t(),
          non_neg_integer(),
          atom() | String.t(),
          {pos_integer(), pos_integer()},
          keyword()
        ) :: {:ok, refactor_result()} | {:error, term()}
  def extract_function(
        module_name,
        source_function,
        source_arity,
        new_function_name,
        line_range,
        opts \\ []
      ) do
    module_atom = to_atom(module_name)
    source_atom = to_atom(source_function)
    new_atom = to_atom(new_function_name)

    Logger.info(
      "Starting refactor: extract #{module_atom}.#{source_atom}/#{source_arity} lines #{inspect(line_range)} into #{new_atom}"
    )

    # Find the module's file
    case Store.find_node(:module, module_atom) do
      nil ->
        {:error, "Module #{module_atom} not found in graph"}

      module_node ->
        file_path = module_node[:file]
        validate = Keyword.get(opts, :validate, true)
        format = Keyword.get(opts, :format, true)

        with {:ok, content} <- File.read(file_path),
             {:ok, new_content} <-
               ElixirRefactor.extract_function(
                 content,
                 module_atom,
                 source_atom,
                 source_arity,
                 new_atom,
                 line_range,
                 opts
               ) do
          # Build transaction to apply the change
          lines = String.split(content, "\n")
          line_count = length(lines)
          changes = [Types.replace(1, line_count, new_content)]

          txn =
            Transaction.new(validate: validate, format: format, create_backup: true)
            |> Transaction.add(file_path, changes)

          result = Transaction.commit(txn)

          case result do
            {:ok, txn_result} ->
              Logger.info("Extract function completed successfully")

              {:ok,
               %{
                 status: :success,
                 files_modified: 1,
                 transaction_result: txn_result
               }}

            {:error, txn_result} ->
              Logger.error("Extract function failed: #{inspect(txn_result.errors)}")

              {:error,
               %{
                 status: :failure,
                 files_modified: 0,
                 rolled_back: txn_result.rolled_back,
                 errors: txn_result.errors
               }}
          end
        else
          {:error, reason} = error ->
            Logger.error("Extract function failed: #{inspect(reason)}")
            error
        end
    end
  end

  @doc """
  Inlines a function by replacing all its calls with the function body.

  ## Parameters
  - `module_name`: Module containing the function
  - `function_name`: Function to inline
  - `arity`: Function arity
  - `opts`: Options
    - `:scope` - :module (same file only) or :project (all files, default: :project)
    - `:remove_definition` - Remove function definition after inlining (default: true)
    - `:validate` - boolean (default: true)
    - `:format` - boolean (default: true)

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure (with rollback)

  ## Examples

      # Inline MyModule.helper/1 across entire project
      Refactor.inline_function(:MyModule, :helper, 1)

      # Inline only within the same module, keep definition
      Refactor.inline_function(
        :MyModule, :helper, 1,
        scope: :module, remove_definition: false
      )
  """
  @spec inline_function(
          atom() | String.t(),
          atom() | String.t(),
          non_neg_integer(),
          keyword()
        ) :: {:ok, refactor_result()} | {:error, term()}
  def inline_function(module_name, function_name, arity, opts \\ []) do
    module_atom = to_atom(module_name)
    function_atom = to_atom(function_name)
    scope = Keyword.get(opts, :scope, :project)
    remove_definition = Keyword.get(opts, :remove_definition, true)

    Logger.info(
      "Starting refactor: inline #{module_atom}.#{function_atom}/#{arity} (scope: #{scope})"
    )

    with {:ok, affected_files} <-
           find_affected_files(module_atom, function_atom, arity, scope),
         {:ok, transaction} <-
           build_inline_transaction(affected_files, function_atom, arity, remove_definition, opts),
         result <- Transaction.commit(transaction) do
      case result do
        {:ok, txn_result} ->
          Logger.info("Inline function completed: #{txn_result.files_edited} files modified")

          {:ok,
           %{
             status: :success,
             files_modified: txn_result.files_edited,
             transaction_result: txn_result
           }}

        {:error, txn_result} ->
          Logger.error("Inline function failed: #{inspect(txn_result.errors)}")

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
        Logger.error("Inline function failed during preparation: #{inspect(reason)}")
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

  # Build transaction for inline function
  defp build_inline_transaction(files, function_name, arity, remove_definition, opts) do
    validate = Keyword.get(opts, :validate, true)
    format = Keyword.get(opts, :format, true)

    txn = Transaction.new(validate: validate, format: format, create_backup: true)

    result =
      Enum.reduce_while(files, {:ok, txn}, fn file_path, {:ok, transaction_acc} ->
        case refactor_file_inline(file_path, function_name, arity, remove_definition) do
          {:ok, changes} ->
            {:cont, {:ok, Transaction.add(transaction_acc, file_path, changes)}}

          {:error, reason} ->
            {:halt, {:error, "Failed to inline in #{file_path}: #{inspect(reason)}"}}
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

  # Generate changes for inlining a function in a file
  defp refactor_file_inline(file_path, function_name, arity, remove_definition) do
    language = detect_language(file_path)

    with {:ok, content} <- File.read(file_path),
         {:ok, new_content} <-
           refactor_inline_content(content, function_name, arity, remove_definition, language) do
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

  # Refactor inline in content based on language
  defp refactor_inline_content(content, function_name, arity, remove_definition, language) do
    case language do
      :elixir ->
        # Use a dummy module name for inline - not used in the function
        ElixirRefactor.inline_function(
          content,
          :DummyModule,
          function_name,
          arity,
          remove_definition: remove_definition
        )

      :erlang ->
        {:error, "Erlang inline refactoring not yet implemented"}

      _ ->
        {:error, "Inline refactoring not supported for language: #{language}"}
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

  @doc """
  Converts function visibility between public (def) and private (defp).

  ## Parameters
  - `module_name`: Module containing the function
  - `function_name`: Function to modify
  - `arity`: Function arity
  - `visibility`: :public or :private
  - `opts`: Options
    - `:add_doc` - Add documentation when making public (default: false)
    - `:validate` - boolean (default: true)
    - `:format` - boolean (default: true)

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  ## Examples

      # Make private function public
      Refactor.convert_visibility(:MyModule, :helper, 1, :public)

      # Make public function private
      Refactor.convert_visibility(:MyModule, :exposed, 2, :private)
  """
  @spec convert_visibility(
          atom() | String.t(),
          atom() | String.t(),
          non_neg_integer(),
          :public | :private,
          keyword()
        ) :: {:ok, refactor_result()} | {:error, term()}
  def convert_visibility(module_name, function_name, arity, visibility, opts \\ []) do
    module_atom = to_atom(module_name)
    function_atom = to_atom(function_name)

    Logger.info(
      "Starting refactor: convert #{module_atom}.#{function_atom}/#{arity} to #{visibility}"
    )

    case Store.find_node(:module, module_atom) do
      nil ->
        {:error, "Module #{module_atom} not found in graph"}

      module_node ->
        file_path = module_node[:file]
        validate = Keyword.get(opts, :validate, true)
        format = Keyword.get(opts, :format, true)

        with {:ok, content} <- File.read(file_path),
             {:ok, new_content} <-
               ElixirRefactor.convert_visibility(
                 content,
                 module_atom,
                 function_atom,
                 arity,
                 visibility,
                 opts
               ) do
          lines = String.split(content, "\n")
          line_count = length(lines)
          changes = [Types.replace(1, line_count, new_content)]

          txn =
            Transaction.new(validate: validate, format: format, create_backup: true)
            |> Transaction.add(file_path, changes)

          result = Transaction.commit(txn)

          case result do
            {:ok, txn_result} ->
              Logger.info("Convert visibility completed successfully")

              {:ok,
               %{
                 status: :success,
                 files_modified: 1,
                 transaction_result: txn_result
               }}

            {:error, txn_result} ->
              Logger.error("Convert visibility failed: #{inspect(txn_result.errors)}")

              {:error,
               %{
                 status: :failure,
                 files_modified: 0,
                 rolled_back: txn_result.rolled_back,
                 errors: txn_result.errors
               }}
          end
        else
          {:error, reason} = error ->
            Logger.error("Convert visibility failed: #{inspect(reason)}")
            error
        end
    end
  end

  @doc """
  Renames a function parameter and all its references within the function body.

  ## Parameters
  - `module_name`: Module containing the function
  - `function_name`: Function to modify
  - `arity`: Function arity
  - `old_param_name`: Current parameter name
  - `new_param_name`: New parameter name
  - `opts`: Options
    - `:validate` - boolean (default: true)
    - `:format` - boolean (default: true)

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  ## Examples

      # Rename parameter x to input
      Refactor.rename_parameter(:MyModule, :process, 1, :x, :input)
  """
  @spec rename_parameter(
          atom() | String.t(),
          atom() | String.t(),
          non_neg_integer(),
          atom() | String.t(),
          atom() | String.t(),
          keyword()
        ) :: {:ok, refactor_result()} | {:error, term()}
  def rename_parameter(
        module_name,
        function_name,
        arity,
        old_param_name,
        new_param_name,
        opts \\ []
      ) do
    module_atom = to_atom(module_name)
    function_atom = to_atom(function_name)
    old_param = to_atom(old_param_name)
    new_param = to_atom(new_param_name)

    Logger.info(
      "Starting refactor: rename parameter #{old_param} to #{new_param} in #{module_atom}.#{function_atom}/#{arity}"
    )

    case Store.find_node(:module, module_atom) do
      nil ->
        {:error, "Module #{module_atom} not found in graph"}

      module_node ->
        file_path = module_node[:file]
        validate = Keyword.get(opts, :validate, true)
        format = Keyword.get(opts, :format, true)

        with {:ok, content} <- File.read(file_path),
             {:ok, new_content} <-
               ElixirRefactor.rename_parameter(
                 content,
                 module_atom,
                 function_atom,
                 arity,
                 old_param,
                 new_param,
                 opts
               ) do
          lines = String.split(content, "\n")
          line_count = length(lines)
          changes = [Types.replace(1, line_count, new_content)]

          txn =
            Transaction.new(validate: validate, format: format, create_backup: true)
            |> Transaction.add(file_path, changes)

          result = Transaction.commit(txn)

          case result do
            {:ok, txn_result} ->
              Logger.info("Rename parameter completed successfully")

              {:ok,
               %{
                 status: :success,
                 files_modified: 1,
                 transaction_result: txn_result
               }}

            {:error, txn_result} ->
              Logger.error("Rename parameter failed: #{inspect(txn_result.errors)}")

              {:error,
               %{
                 status: :failure,
                 files_modified: 0,
                 rolled_back: txn_result.rolled_back,
                 errors: txn_result.errors
               }}
          end
        else
          {:error, reason} = error ->
            Logger.error("Rename parameter failed: #{inspect(reason)}")
            error
        end
    end
  end

  @doc """
  Adds, removes, or updates module attributes.

  ## Parameters
  - `module_name`: Module to modify
  - `changes`: Map with :add, :remove, and/or :update keys
  - `opts`: Options
    - `:validate` - boolean (default: true)
    - `:format` - boolean (default: true)

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  ## Examples

      # Add and update attributes
      changes = %{
        add: [{:vsn, "1.0.0"}],
        remove: [:deprecated],
        update: [{:moduledoc, "Updated docs"}]
      }
      Refactor.modify_attributes(:MyModule, changes)
  """
  @spec modify_attributes(atom() | String.t(), map(), keyword()) ::
          {:ok, refactor_result()} | {:error, term()}
  def modify_attributes(module_name, changes, opts \\ []) do
    module_atom = to_atom(module_name)

    Logger.info("Starting refactor: modify attributes in #{module_atom}")

    case Store.find_node(:module, module_atom) do
      nil ->
        {:error, "Module #{module_atom} not found in graph"}

      module_node ->
        file_path = module_node[:file]
        validate = Keyword.get(opts, :validate, true)
        format = Keyword.get(opts, :format, true)

        with {:ok, content} <- File.read(file_path),
             {:ok, new_content} <- ElixirRefactor.modify_attributes(content, changes, opts) do
          lines = String.split(content, "\n")
          line_count = length(lines)
          changes_list = [Types.replace(1, line_count, new_content)]

          txn =
            Transaction.new(validate: validate, format: format, create_backup: true)
            |> Transaction.add(file_path, changes_list)

          result = Transaction.commit(txn)

          case result do
            {:ok, txn_result} ->
              Logger.info("Modify attributes completed successfully")

              {:ok,
               %{
                 status: :success,
                 files_modified: 1,
                 transaction_result: txn_result
               }}

            {:error, txn_result} ->
              Logger.error("Modify attributes failed: #{inspect(txn_result.errors)}")

              {:error,
               %{
                 status: :failure,
                 files_modified: 0,
                 rolled_back: txn_result.rolled_back,
                 errors: txn_result.errors
               }}
          end
        else
          {:error, reason} = error ->
            Logger.error("Modify attributes failed: #{inspect(reason)}")
            error
        end
    end
  end

  @doc """
  Changes a function signature by adding, removing, reordering, or renaming parameters.

  ## Parameters
  - `module_name`: Module containing the function
  - `function_name`: Function to modify
  - `old_arity`: Current function arity
  - `signature_changes`: Map describing the changes (see details below)
  - `opts`: Options
    - `:scope` - :module (same file only) or :project (all files, default: :project)
    - `:validate` - boolean (default: true)
    - `:format` - boolean (default: true)

  ## Signature Changes Format

  The `signature_changes` map can contain:
  - `:add_params` - List of params to add with defaults
  - `:remove_params` - List of param positions to remove (0-indexed)
  - `:reorder_params` - New param order
  - `:rename_params` - List of renames

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure (with rollback)

  ## Examples

      # Add an optional parameter
      changes = %{add_params: [%{name: :opts, position: 2, default: []}]}
      Refactor.change_signature(:MyModule, :process, 2, changes)

      # Remove second parameter and rename first
      changes = %{
        remove_params: [1],
        rename_params: [{:old_name, :new_name}]
      }
      Refactor.change_signature(:MyModule, :transform, 3, changes)
  """
  @spec change_signature(
          atom() | String.t(),
          atom() | String.t(),
          non_neg_integer(),
          map(),
          keyword()
        ) :: {:ok, refactor_result()} | {:error, term()}
  def change_signature(module_name, function_name, old_arity, signature_changes, opts \\ []) do
    module_atom = to_atom(module_name)
    function_atom = to_atom(function_name)
    scope = Keyword.get(opts, :scope, :project)

    Logger.info(
      "Starting refactor: change signature #{module_atom}.#{function_atom}/#{old_arity} (scope: #{scope})"
    )

    with {:ok, affected_files} <-
           find_affected_files(module_atom, function_atom, old_arity, scope),
         {:ok, transaction} <-
           build_signature_change_transaction(
             affected_files,
             function_atom,
             old_arity,
             signature_changes,
             opts
           ),
         result <- Transaction.commit(transaction) do
      case result do
        {:ok, txn_result} ->
          Logger.info("Change signature completed: #{txn_result.files_edited} files modified")

          {:ok,
           %{
             status: :success,
             files_modified: txn_result.files_edited,
             transaction_result: txn_result
           }}

        {:error, txn_result} ->
          Logger.error("Change signature failed: #{inspect(txn_result.errors)}")

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
        Logger.error("Change signature failed during preparation: #{inspect(reason)}")
        error
    end
  end

  # Build transaction for signature change
  defp build_signature_change_transaction(
         files,
         function_name,
         old_arity,
         signature_changes,
         opts
       ) do
    validate = Keyword.get(opts, :validate, true)
    format = Keyword.get(opts, :format, true)

    txn = Transaction.new(validate: validate, format: format, create_backup: true)

    result =
      Enum.reduce_while(files, {:ok, txn}, fn file_path, {:ok, transaction_acc} ->
        case refactor_file_signature(file_path, function_name, old_arity, signature_changes) do
          {:ok, changes} ->
            {:cont, {:ok, Transaction.add(transaction_acc, file_path, changes)}}

          {:error, reason} ->
            {:halt, {:error, "Failed to change signature in #{file_path}: #{inspect(reason)}"}}
        end
      end)

    case result do
      {:ok, _transaction} = success -> success
      {:error, _reason} = error -> error
    end
  end

  # Generate changes for signature change in a file
  defp refactor_file_signature(file_path, function_name, old_arity, signature_changes) do
    language = detect_language(file_path)

    with {:ok, content} <- File.read(file_path),
         {:ok, new_content} <-
           refactor_signature_content(
             content,
             function_name,
             old_arity,
             signature_changes,
             language
           ) do
      lines = String.split(content, "\n")
      line_count = length(lines)

      changes = [Types.replace(1, line_count, new_content)]
      {:ok, changes}
    end
  end

  # Refactor signature in content based on language
  defp refactor_signature_content(content, function_name, old_arity, signature_changes, language) do
    case language do
      :elixir ->
        ElixirRefactor.change_signature(
          content,
          :DummyModule,
          function_name,
          old_arity,
          signature_changes
        )

      :erlang ->
        {:error, "Erlang signature change not yet implemented"}

      _ ->
        {:error, "Signature change not supported for language: #{language}"}
    end
  end

  @doc """
  Moves a function from one module to another.

  ## Parameters
  - `source_module`: Source module name
  - `target_module`: Target module name
  - `function_name`: Function to move
  - `arity`: Function arity
  - `opts`: Options
    - `:placement` - :start | :end (default: :end)
    - `:update_references` - boolean (default: true)
    - `:validate` - boolean (default: true)
    - `:format` - boolean (default: true)

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure (with rollback)

  ## Examples

      # Move function to existing module
      Refactor.move_function(:MyModule, :MyModule.Utils, :helper, 1)
  """
  @spec move_function(
          atom() | String.t(),
          atom() | String.t(),
          atom() | String.t(),
          non_neg_integer(),
          keyword()
        ) :: {:ok, refactor_result()} | {:error, term()}
  def move_function(source_module, target_module, function_name, arity, opts \\ []) do
    source_atom = to_atom(source_module)
    target_atom = to_atom(target_module)
    function_atom = to_atom(function_name)

    Logger.info(
      "Starting refactor: move #{source_atom}.#{function_atom}/#{arity} to #{target_atom}"
    )

    with {:ok, source_file} <- get_module_file(source_atom),
         {:ok, source_content} <- File.read(source_file),
         target_result <- get_module_file(target_atom),
         target_content <- read_target_content(target_result),
         {:ok, result} <-
           ElixirRefactor.move_function(
             source_content,
             target_content,
             source_atom,
             target_atom,
             function_atom,
             arity,
             opts
           ) do
      # Determine target file path
      target_file =
        case target_result do
          {:ok, path} -> path
          {:error, _} -> derive_file_path(target_atom)
        end

      # Build transaction
      validate = Keyword.get(opts, :validate, true)
      format = Keyword.get(opts, :format, true)

      source_lines = String.split(source_content, "\n")
      source_changes = [Types.replace(1, length(source_lines), result.source)]

      target_lines = String.split(target_content || "", "\n")
      target_line_count = if target_content, do: length(target_lines), else: 0

      target_changes =
        if target_line_count > 0 do
          [Types.replace(1, target_line_count, result.target)]
        else
          [Types.insert(1, result.target)]
        end

      txn =
        Transaction.new(validate: validate, format: format, create_backup: true)
        |> Transaction.add(source_file, source_changes)
        |> Transaction.add(target_file, target_changes)

      case Transaction.commit(txn) do
        {:ok, txn_result} ->
          Logger.info("Move function completed: #{txn_result.files_edited} files modified")

          {:ok,
           %{
             status: :success,
             files_modified: txn_result.files_edited,
             transaction_result: txn_result
           }}

        {:error, txn_result} ->
          Logger.error("Move function failed: #{inspect(txn_result.errors)}")

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
        Logger.error("Move function failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Extracts multiple functions from a module into a new module.

  ## Parameters
  - `source_module`: Source module name
  - `new_module`: New module name
  - `functions`: List of {function_name, arity} tuples
  - `opts`: Options
    - `:file_path` - Explicit path for new module (optional)
    - `:add_moduledoc` - boolean (default: true)
    - `:update_aliases` - boolean (default: true)
    - `:validate` - boolean (default: true)
    - `:format` - boolean (default: true)

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure (with rollback)

  ## Examples

      # Extract helpers into new module
      functions = [{:helper1, 1}, {:helper2, 2}]
      Refactor.extract_module(:MyModule, :MyModule.Helpers, functions)
  """
  @spec extract_module(
          atom() | String.t(),
          atom() | String.t(),
          [{atom(), non_neg_integer()}],
          keyword()
        ) :: {:ok, refactor_result()} | {:error, term()}
  def extract_module(source_module, new_module, functions, opts \\ []) do
    source_atom = to_atom(source_module)
    new_atom = to_atom(new_module)

    Logger.info("Starting refactor: extract module #{new_atom} from #{source_atom}")

    with {:ok, source_file} <- get_module_file(source_atom),
         {:ok, source_content} <- File.read(source_file),
         {:ok, result} <-
           ElixirRefactor.extract_module(
             source_content,
             source_atom,
             new_atom,
             functions,
             opts
           ) do
      # Determine new module file path
      new_file = Keyword.get(opts, :file_path) || derive_file_path(new_atom)

      # Build transaction
      validate = Keyword.get(opts, :validate, true)
      format = Keyword.get(opts, :format, true)

      source_lines = String.split(source_content, "\n")
      source_changes = [Types.replace(1, length(source_lines), result.source)]

      # For new file, use insert
      new_changes = [Types.insert(1, result.target)]

      txn =
        Transaction.new(validate: validate, format: format, create_backup: true)
        |> Transaction.add(source_file, source_changes)
        |> Transaction.add(new_file, new_changes)

      case Transaction.commit(txn) do
        {:ok, txn_result} ->
          Logger.info("Extract module completed: #{txn_result.files_edited} files modified")

          {:ok,
           %{
             status: :success,
             files_modified: txn_result.files_edited,
             transaction_result: txn_result,
             new_file: new_file
           }}

        {:error, txn_result} ->
          Logger.error("Extract module failed: #{inspect(txn_result.errors)}")

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
        Logger.error("Extract module failed: #{inspect(reason)}")
        error
    end
  end

  # Helper to get module file from graph
  defp get_module_file(module_atom) do
    case Store.find_node(:module, module_atom) do
      nil -> {:error, "Module #{module_atom} not found in graph"}
      node -> {:ok, node[:file]}
    end
  end

  # Helper to read target content (may not exist)
  defp read_target_content({:ok, path}) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp read_target_content({:error, _}), do: nil

  # Derive file path from module name
  defp derive_file_path(module_atom) do
    # Convert MyModule.SubModule to lib/my_module/sub_module.ex
    parts =
      module_atom
      |> Atom.to_string()
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    filename = List.last(parts) <> ".ex"
    dir_parts = Enum.drop(parts, -1)

    path_parts = ["lib" | dir_parts] ++ [filename]
    Path.join(path_parts)
  end

  # Find project root from a file path
  defp find_project_root(file_path) do
    # Walk up directory tree looking for mix.exs, rebar.config, or similar
    dir = Path.dirname(file_path)

    cond do
      File.exists?(Path.join(dir, "mix.exs")) -> dir
      File.exists?(Path.join(dir, "rebar.config")) -> dir
      File.exists?(Path.join(dir, "package.json")) -> dir
      dir == "/" -> file_path
      true -> find_project_root(dir)
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
