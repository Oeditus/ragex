defmodule Ragex.Editor.Conflict do
  @moduledoc """
  Conflict detection for refactoring operations.

  Detects potential conflicts before applying refactoring changes:
  - Name conflicts (duplicate names)
  - Scope conflicts (visibility issues)
  - Dependency conflicts (broken references)
  - Concurrent modifications (file changed since analysis)
  - Visibility conflicts (private function made public with broken callers)
  """

  alias Ragex.Graph.Store
  require Logger

  @type conflict_type ::
          :name_conflict
          | :scope_conflict
          | :dependency_conflict
          | :concurrent_modification
          | :visibility_conflict

  @type conflict :: %{
          type: conflict_type(),
          severity: :error | :warning | :info,
          message: String.t(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          suggestion: String.t() | nil
        }

  @type conflict_result :: %{
          has_conflicts: boolean(),
          conflicts: [conflict()],
          stats: %{
            errors: non_neg_integer(),
            warnings: non_neg_integer(),
            infos: non_neg_integer()
          }
        }

  @doc """
  Checks for naming conflicts when renaming a function.

  ## Parameters
  - `module_name`: Module containing the function
  - `new_name`: Proposed new name
  - `arity`: Function arity

  ## Returns
  - `{:ok, conflict_result}` with any detected conflicts
  """
  @spec check_rename_conflicts(atom(), atom(), non_neg_integer()) ::
          {:ok, conflict_result()}
  def check_rename_conflicts(module_name, new_name, arity) do
    conflicts = []

    # Check if target name already exists in module
    conflicts =
      case Store.find_node(:function, {module_name, new_name, arity}) do
        nil ->
          conflicts

        existing ->
          [
            %{
              type: :name_conflict,
              severity: :error,
              message:
                "Function #{module_name}.#{new_name}/#{arity} already exists at #{existing[:file]}:#{existing[:line]}",
              file: existing[:file],
              line: existing[:line],
              suggestion: "Choose a different name or remove the existing function first"
            }
            | conflicts
          ]
      end

    # Check for similar names (potential confusion)
    conflicts = conflicts ++ check_similar_names(module_name, new_name, arity)

    build_result(conflicts)
  end

  @doc """
  Checks for conflicts when moving a function between modules.

  ## Parameters
  - `source_module`: Source module
  - `target_module`: Target module
  - `function_name`: Function to move
  - `arity`: Function arity

  ## Returns
  - `{:ok, conflict_result}` with any detected conflicts
  """
  @spec check_move_conflicts(atom(), atom(), atom(), non_neg_integer()) ::
          {:ok, conflict_result()}
  def check_move_conflicts(source_module, target_module, function_name, arity) do
    conflicts = []

    # Check if function exists in source
    conflicts =
      case Store.find_node(:function, {source_module, function_name, arity}) do
        nil ->
          [
            %{
              type: :dependency_conflict,
              severity: :error,
              message: "Function #{source_module}.#{function_name}/#{arity} not found in graph",
              file: nil,
              line: nil,
              suggestion: "Ensure the source module has been analyzed"
            }
            | conflicts
          ]

        _existing ->
          conflicts
      end

    # Check if target already has this function
    conflicts =
      case Store.find_node(:function, {target_module, function_name, arity}) do
        nil ->
          conflicts

        existing ->
          [
            %{
              type: :name_conflict,
              severity: :error,
              message: "Function #{target_module}.#{function_name}/#{arity} already exists",
              file: existing[:file],
              line: existing[:line],
              suggestion: "Rename the function or remove the existing one first"
            }
            | conflicts
          ]
      end

    # Check for dependency issues
    conflicts = conflicts ++ check_dependency_conflicts(source_module, function_name, arity)

    build_result(conflicts)
  end

  @doc """
  Checks for conflicts when extracting a module.

  ## Parameters
  - `source_module`: Module to extract from
  - `new_module`: Name for new module
  - `functions`: List of {name, arity} tuples to extract

  ## Returns
  - `{:ok, conflict_result}` with any detected conflicts
  """
  @spec check_extract_module_conflicts(atom(), atom(), [{atom(), non_neg_integer()}]) ::
          {:ok, conflict_result()}
  def check_extract_module_conflicts(source_module, new_module, functions) do
    conflicts = []

    # Check if new module name conflicts
    conflicts =
      case Store.find_node(:module, new_module) do
        nil ->
          conflicts

        existing ->
          [
            %{
              type: :name_conflict,
              severity: :error,
              message: "Module #{new_module} already exists at #{existing[:file]}",
              file: existing[:file],
              line: nil,
              suggestion: "Choose a different module name"
            }
            | conflicts
          ]
      end

    # Check each function exists in source
    conflicts =
      Enum.reduce(functions, conflicts, fn {name, arity}, acc ->
        case Store.find_node(:function, {source_module, name, arity}) do
          nil ->
            [
              %{
                type: :dependency_conflict,
                severity: :error,
                message: "Function #{source_module}.#{name}/#{arity} not found in source module",
                file: nil,
                line: nil,
                suggestion: "Verify function exists before extracting"
              }
              | acc
            ]

          _existing ->
            acc
        end
      end)

    # Check for inter-dependencies between extracted functions
    conflicts = conflicts ++ check_extraction_dependencies(source_module, functions)

    build_result(conflicts)
  end

  @doc """
  Checks for concurrent file modifications.

  ## Parameters
  - `file_path`: Path to file
  - `expected_mtime`: Expected modification time (from when analysis was done)

  ## Returns
  - `{:ok, conflict_result}` with any detected conflicts
  """
  @spec check_concurrent_modification(String.t(), integer() | nil) ::
          {:ok, conflict_result()}
  def check_concurrent_modification(file_path, expected_mtime) when is_integer(expected_mtime) do
    conflicts =
      case File.stat(file_path) do
        {:ok, %{mtime: current_mtime}} ->
          current_timestamp = :calendar.datetime_to_gregorian_seconds(current_mtime)

          if current_timestamp != expected_mtime do
            [
              %{
                type: :concurrent_modification,
                severity: :warning,
                message: "File #{file_path} has been modified since analysis",
                file: file_path,
                line: nil,
                suggestion: "Re-analyze the file before refactoring to ensure accuracy"
              }
            ]
          else
            []
          end

        {:error, _reason} ->
          [
            %{
              type: :dependency_conflict,
              severity: :error,
              message: "Cannot access file #{file_path}",
              file: file_path,
              line: nil,
              suggestion: "Ensure file exists and is readable"
            }
          ]
      end

    build_result(conflicts)
  end

  def check_concurrent_modification(_file_path, nil) do
    # No expected mtime, skip check
    build_result([])
  end

  @doc """
  Checks for visibility conflicts when changing function visibility.

  ## Parameters
  - `module_name`: Module containing function
  - `function_name`: Function name
  - `arity`: Function arity
  - `new_visibility`: :public or :private

  ## Returns
  - `{:ok, conflict_result}` with any detected conflicts
  """
  @spec check_visibility_conflicts(atom(), atom(), non_neg_integer(), :public | :private) ::
          {:ok, conflict_result()}
  def check_visibility_conflicts(module_name, function_name, arity, new_visibility) do
    conflicts = []

    # If making private, check for external callers
    conflicts =
      if new_visibility == :private do
        Store.get_incoming_edges({:function, module_name, function_name, arity}, :calls)
        |> Enum.map(fn %{from: from_node} -> from_node end)
        |> Enum.filter(fn {:function, caller_module, _name, _arity} ->
          caller_module != module_name
        end)
        |> case do
          [_ | _] = external_callers ->
            [
              %{
                type: :visibility_conflict,
                severity: :error,
                message:
                  "Cannot make #{module_name}.#{function_name}/#{arity} private: #{length(external_callers)} external caller(s)",
                file: nil,
                line: nil,
                suggestion: "Update or remove external callers first, or keep function public"
              }
              | conflicts
            ]

          _ ->
            conflicts
        end
      else
        conflicts
      end

    build_result(conflicts)
  end

  # Private functions

  defp check_similar_names(module_name, new_name, arity) do
    # Find functions with similar names (Levenshtein distance <= 2)
    module_functions =
      Store.get_outgoing_edges({:module, module_name}, :defines)
      |> Enum.map(fn %{to: to_node} -> to_node end)
      |> Enum.filter(fn {:function, _mod, name, ar} ->
        ar == arity and name != new_name and similar?(name, new_name)
      end)

    Enum.map(module_functions, fn {:function, _mod, similar_name, _ar} ->
      %{
        type: :name_conflict,
        severity: :warning,
        message: "Similar function name exists: #{similar_name} (may cause confusion)",
        file: nil,
        line: nil,
        suggestion: "Consider choosing a more distinct name"
      }
    end)
  end

  defp similar?(name1, name2) do
    str1 = Atom.to_string(name1)
    str2 = Atom.to_string(name2)
    distance = String.jaro_distance(str1, str2)
    distance > 0.8
  end

  defp check_dependency_conflicts(module_name, function_name, arity) do
    # Check if function calls private functions from source module
    function_node = {:function, module_name, function_name, arity}

    case Store.find_node(:function, {module_name, function_name, arity}) do
      nil ->
        []

      _exists ->
        # Get functions this function calls
        callees =
          Store.get_outgoing_edges(function_node, :calls)
          |> Enum.map(fn %{to: to_node} -> to_node end)
          |> Enum.filter(fn {:function, callee_module, _name, _arity} ->
            callee_module == module_name
          end)

        # Check if any callees are private
        Enum.filter(callees, fn {:function, mod, name, ar} ->
          case Store.find_node(:function, {mod, name, ar}) do
            nil -> false
            node -> node[:visibility] == :private
          end
        end)
        |> Enum.map(fn {:function, _mod, callee_name, callee_arity} ->
          %{
            type: :dependency_conflict,
            severity: :warning,
            message: "Function calls private function #{callee_name}/#{callee_arity}",
            file: nil,
            line: nil,
            suggestion: "Make the callee public or move it along with this function"
          }
        end)
    end
  end

  defp check_extraction_dependencies(source_module, functions) do
    # Check if extracted functions call non-extracted functions
    function_set = MapSet.new(functions)

    Enum.flat_map(functions, fn {name, arity} ->
      function_node = {:function, source_module, name, arity}

      case Store.find_node(:function, {source_module, name, arity}) do
        nil ->
          []

        _exists ->
          # Get callees
          Store.get_outgoing_edges(function_node, :calls)
          |> Enum.map(fn %{to: to_node} -> to_node end)
          |> Enum.filter(fn {:function, callee_module, callee_name, callee_arity} ->
            # Same module, not in extraction set
            callee_module == source_module and
              not MapSet.member?(function_set, {callee_name, callee_arity})
          end)
          |> Enum.map(fn {:function, _mod, callee_name, callee_arity} ->
            %{
              type: :dependency_conflict,
              severity: :info,
              message:
                "#{name}/#{arity} calls #{callee_name}/#{callee_arity} which remains in source module",
              file: nil,
              line: nil,
              suggestion:
                "Consider extracting dependent functions or accepting cross-module dependency"
            }
          end)
      end
    end)
  end

  defp build_result(conflicts) do
    stats =
      Enum.reduce(conflicts, %{errors: 0, warnings: 0, infos: 0}, fn conflict, acc ->
        case conflict.severity do
          :error -> %{acc | errors: acc.errors + 1}
          :warning -> %{acc | warnings: acc.warnings + 1}
          :info -> %{acc | infos: acc.infos + 1}
        end
      end)

    {:ok,
     %{
       has_conflicts: match?([_ | _], conflicts),
       conflicts: conflicts,
       stats: stats
     }}
  end
end
