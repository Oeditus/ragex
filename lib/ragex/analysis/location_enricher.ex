defmodule Ragex.Analysis.LocationEnricher do
  @moduledoc """
  Enriches analysis results with accurate location information from the knowledge graph.

  ## Purpose

  Metastatic's MetaAST abstraction intentionally strips language-specific details like
  line numbers to enable language-agnostic analysis. However, Ragex's knowledge graph
  contains accurate location information extracted during initial code analysis.

  This module bridges the gap by enriching Metastatic analysis results with location
  data from the knowledge graph.

  ## Usage

      alias Ragex.Analysis.LocationEnricher

      # Enrich a single issue/smell
      enriched = LocationEnricher.enrich_issue(issue, file_path)

      # Enrich list of issues
      enriched_list = LocationEnricher.enrich_issues(issues, file_path)

      # Find function containing a location
      {:ok, func} = LocationEnricher.find_function_at_location(file_path, line: 42)

  ## Enrichment Strategy

  1. **Direct match**: If issue has function/module context, match against graph
  2. **Line-based match**: Find function containing the reported line number
  3. **File-based fallback**: Return file-level location if no function match
  4. **Preserve original**: Keep Metastatic data if graph unavailable
  """

  alias Ragex.Graph.Store
  require Logger

  @type location :: %{
          optional(:file) => String.t(),
          optional(:line) => non_neg_integer() | nil,
          optional(:column) => non_neg_integer() | nil,
          optional(:module) => atom() | nil,
          optional(:function) => atom() | nil,
          optional(:arity) => non_neg_integer() | nil,
          optional(:formatted) => String.t()
        }

  @type issue :: %{
          optional(:location) => location() | nil,
          optional(:line) => non_neg_integer() | nil,
          optional(:column) => non_neg_integer() | nil,
          optional(:file) => String.t() | nil,
          optional(:context) => map()
        }

  @doc """
  Enriches a single issue with location data from the knowledge graph.

  ## Parameters
  - `issue` - Issue map from analysis (must have file or location)
  - `file_path` - Optional file path override

  ## Returns
  Enriched issue with updated location fields
  """
  @spec enrich_issue(issue(), String.t() | nil) :: issue()
  def enrich_issue(issue, file_path \\ nil) do
    file = file_path || Map.get(issue, :file)

    if file do
      # Get existing location data
      existing_location = Map.get(issue, :location)
      existing_line = Map.get(issue, :line)

      # Try to find better location from knowledge graph
      enriched_location = enrich_location(existing_location, existing_line, file, issue)

      # Update issue with enriched location
      issue
      |> Map.put(:location, enriched_location)
      |> Map.put(:line, enriched_location[:line])
      |> Map.put(:column, enriched_location[:column])
      |> Map.put(:file, file)
    else
      issue
    end
  end

  @doc """
  Enriches a list of issues with location data.
  """
  @spec enrich_issues([issue()], String.t() | nil) :: [issue()]
  def enrich_issues(issues, file_path \\ nil) when is_list(issues) do
    Enum.map(issues, &enrich_issue(&1, file_path))
  end

  @doc """
  Finds the function at a specific location in a file.

  ## Parameters
  - `file_path` - Path to source file
  - `opts` - Keyword list with `:line` or `:module` and `:function`

  ## Returns
  - `{:ok, function_info}` - Function metadata from graph
  - `{:error, :not_found}` - No matching function found
  """
  @spec find_function_at_location(String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def find_function_at_location(file_path, opts) do
    normalized_path = Path.expand(file_path)

    case {Keyword.get(opts, :line), Keyword.get(opts, :module), Keyword.get(opts, :function)} do
      {line, nil, nil} when is_integer(line) ->
        find_function_by_line(normalized_path, line)

      {_, module, function} when not is_nil(module) and not is_nil(function) ->
        arity = Keyword.get(opts, :arity)
        find_function_by_name(module, function, arity)

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Extracts code snippet from a file given line range.

  ## Parameters
  - `file_path` - Path to source file
  - `start_line` - Starting line number (1-indexed)
  - `end_line` - Ending line number (1-indexed)

  ## Returns
  - `{:ok, snippet}` - Code snippet as string
  - `{:error, reason}` - Failed to read file
  """
  @spec extract_snippet(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def extract_snippet(file_path, start_line, end_line) when start_line <= end_line do
    case File.read(file_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        snippet =
          lines
          |> Enum.slice((start_line - 1)..(end_line - 1)//1)
          |> Enum.join("\n")

        {:ok, snippet}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def extract_snippet(_file_path, _start_line, _end_line) do
    {:error, :invalid_range}
  end

  # Private functions

  defp enrich_location(existing_location, existing_line, file, issue) do
    # Determine the line to search for
    search_line =
      cond do
        # Use line from existing location
        existing_location && Map.get(existing_location, :line) ->
          Map.get(existing_location, :line)

        # Use top-level line field
        existing_line ->
          existing_line

        # Try to extract from context
        true ->
          extract_line_from_context(issue)
      end

    # Try to find function from knowledge graph
    # First try by function name from context (common in Metastatic smells)
    result =
      case extract_function_from_context(issue) do
        {:ok, func_name} ->
          # Try to find function by name across all modules in this file
          find_function_by_name_in_file(file, func_name)

        :error ->
          {:error, :not_found}
      end

    # Fallback to line-based search if name search failed
    result =
      case result do
        {:ok, _} = found -> found
        {:error, :not_found} -> find_function_by_line(file, search_line)
      end

    case result do
      {:ok, func_info} ->
        # Build enriched location with graph data
        build_enriched_location(func_info, existing_location, file)

      {:error, :not_found} ->
        # No function found, return file-level location
        build_file_location(file, search_line, existing_location)
    end
  end

  defp extract_line_from_context(issue) do
    context = Map.get(issue, :context, %{})

    cond do
      Map.has_key?(context, :line) -> context.line
      Map.has_key?(context, :start_line) -> context.start_line
      true -> nil
    end
  end

  defp extract_function_from_context(issue) do
    context = Map.get(issue, :context, %{})

    cond do
      # Metastatic smells often have function_name in context
      Map.has_key?(context, :function_name) ->
        func_name = context.function_name
        # Convert to atom if it's a string
        func_atom = if is_binary(func_name), do: String.to_atom(func_name), else: func_name
        {:ok, func_atom}

      # Also check for :function field
      Map.has_key?(context, :function) ->
        func_name = context.function
        func_atom = if is_binary(func_name), do: String.to_atom(func_name), else: func_name
        {:ok, func_atom}

      true ->
        :error
    end
  end

  defp find_function_by_name_in_file(file_path, function_name) do
    normalized_path = Path.expand(file_path)

    try do
      # Find all functions in this file
      functions =
        Store.list_functions(limit: 100_000)
        |> Enum.filter(fn
          %{data: %{file: file}} when is_binary(file) ->
            Path.expand(file) == normalized_path

          _ ->
            false
        end)

      # Find function with matching name (any arity)
      functions
      |> Enum.find(fn %{id: {_module, func, _arity}} ->
        func == function_name
      end)
      |> case do
        nil ->
          {:error, :not_found}

        func_node ->
          {:ok, build_function_info(func_node)}
      end
    catch
      :exit, _ ->
        # Graph store not running
        {:error, :not_found}
    end
  end

  defp find_function_by_line(_file_path, nil), do: {:error, :not_found}

  defp find_function_by_line(file_path, line) when is_integer(line) do
    normalized_path = Path.expand(file_path)

    try do
      functions =
        Store.list_functions(limit: 100_000)
        |> Enum.filter(fn
          %{data: %{file: file, line: line}} when is_binary(file) and not is_nil(line) ->
            Path.expand(file) == normalized_path

          _ ->
            false
        end)
        |> Enum.sort_by(& &1.data.line, :asc)

      # Find function that contains this line
      # (function whose line is <= target line and is the closest)
      case functions do
        [] ->
          {:error, :not_found}

        funcs ->
          # Find the function whose start line is <= target line
          # and is the maximum such line (closest function before target)
          funcs
          |> Enum.filter(fn func -> func.data.line <= line end)
          |> Enum.max_by(fn func -> func.data.line end, fn -> nil end)
          |> case do
            nil ->
              # No function found before this line, maybe it's in the first function?
              # Return first function as fallback
              {:ok, build_function_info(List.first(funcs))}

            func_node ->
              {:ok, build_function_info(func_node)}
          end
      end
    catch
      :exit, _ ->
        # Graph store not running
        {:error, :not_found}
    end
  end

  defp find_function_by_name(module, function, arity) do
    # Try exact match with arity
    if arity do
      case Store.get_function(module, function, arity) do
        nil -> find_function_by_name_no_arity(module, function)
        func_data -> {:ok, build_function_info_from_data({module, function, arity}, func_data)}
      end
    else
      find_function_by_name_no_arity(module, function)
    end
  catch
    :exit, _ ->
      {:error, :not_found}
  end

  defp find_function_by_name_no_arity(module, function) do
    # Search for any arity
    Store.list_functions(limit: 100_000)
    |> Enum.find(fn func_node ->
      {mod, func, _arity} = func_node.id
      mod == module && func == function
    end)
    |> case do
      nil -> {:error, :not_found}
      func_node -> {:ok, build_function_info(func_node)}
    end
  catch
    :exit, _ ->
      {:error, :not_found}
  end

  defp build_function_info(%{id: {module, function, arity}, data: data}) do
    %{
      module: module,
      function: function,
      arity: arity,
      file: Map.get(data, :file),
      line: Map.get(data, :line)
    }
  end

  defp build_function_info_from_data({module, function, arity}, data) do
    %{
      module: module,
      function: function,
      arity: arity,
      file: Map.get(data, :file),
      line: Map.get(data, :line)
    }
  end

  defp build_enriched_location(func_info, existing_location, _file) do
    base_location = %{
      file: func_info.file,
      line: func_info.line,
      module: func_info.module,
      function: func_info.function,
      arity: func_info.arity
    }

    # Preserve column info from existing location if available
    base_location =
      if existing_location && Map.has_key?(existing_location, :column) do
        Map.put(base_location, :column, existing_location.column)
      else
        Map.put(base_location, :column, nil)
      end

    # Add formatted string
    formatted = format_location(base_location)
    Map.put(base_location, :formatted, formatted)
  end

  defp build_file_location(file, line, existing_location) do
    base_location = %{
      file: file,
      line: line
    }

    # Preserve any existing metadata, but prioritize known good values
    # (e.g., don't overwrite with nil or less specific data)
    base_location =
      if existing_location do
        # Merge but keep our file/line as authoritative
        existing_location
        |> Map.take([:module, :function, :arity, :column, :end_line, :end_column])
        |> then(fn existing_meta ->
          # Convert string function names to atoms for consistency
          existing_meta =
            if Map.has_key?(existing_meta, :function) && is_binary(existing_meta.function) do
              Map.update!(existing_meta, :function, &String.to_atom/1)
            else
              existing_meta
            end

          Map.merge(base_location, existing_meta)
        end)
      else
        base_location
      end

    # Add formatted string
    formatted = format_location(base_location)
    Map.put(base_location, :formatted, formatted)
  end

  defp format_location(%{module: mod, function: func, arity: arity, line: line})
       when not is_nil(mod) and not is_nil(func) and not is_nil(arity) and not is_nil(line) do
    func_str = if is_atom(func), do: Atom.to_string(func), else: to_string(func)
    "#{inspect(mod)}.#{func_str}/#{arity}:#{line}"
  end

  defp format_location(%{module: mod, function: func, arity: arity})
       when not is_nil(mod) and not is_nil(func) and not is_nil(arity) do
    func_str = if is_atom(func), do: Atom.to_string(func), else: to_string(func)
    "#{inspect(mod)}.#{func_str}/#{arity}"
  end

  defp format_location(%{file: file, line: line}) when not is_nil(file) and not is_nil(line) do
    "#{file}:#{line}"
  end

  defp format_location(%{file: file}) when not is_nil(file) do
    file
  end

  defp format_location(_), do: "unknown"
end
