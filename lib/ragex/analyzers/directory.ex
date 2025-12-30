defmodule Ragex.Analyzers.Directory do
  @moduledoc """
  Analyzes entire directories recursively, detecting and analyzing files
  based on their extensions.

  This module provides batch analysis capabilities for entire projects.
  """

  alias Ragex.Analyzers.Elixir, as: ElixirAnalyzer
  alias Ragex.Analyzers.Erlang, as: ErlangAnalyzer
  alias Ragex.Analyzers.Python, as: PythonAnalyzer
  alias Ragex.Analyzers.JavaScript, as: JavaScriptAnalyzer
  alias Ragex.Graph.Store
  alias Ragex.Embeddings.FileTracker

  @doc """
  Analyzes all supported files in a directory recursively.

  Returns a summary of analyzed files and any errors encountered.

  ## Options

  - `:max_depth` - Maximum directory depth (default: 10)
  - `:exclude_patterns` - Patterns to exclude (default: common build dirs)
  - `:incremental` - Enable incremental updates (default: true)
  - `:force_refresh` - Force full refresh even if unchanged (default: false)
  """
  def analyze_directory(path, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 10)
    exclude_patterns = Keyword.get(opts, :exclude_patterns, default_exclude_patterns())
    incremental = Keyword.get(opts, :incremental, true)
    force_refresh = Keyword.get(opts, :force_refresh, false)

    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        files = find_supported_files(path, max_depth, exclude_patterns)
        analyze_files(files, incremental: incremental, force_refresh: force_refresh)

      {:ok, %File.Stat{type: :regular}} ->
        # Single file provided
        analyze_files([path], incremental: incremental, force_refresh: force_refresh)

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  @doc """
  Analyzes multiple files and stores results in the graph.

  ## Options

  - `:incremental` - Skip unchanged files (default: true)
  - `:force_refresh` - Force analysis even if unchanged (default: false)
  """
  def analyze_files(file_paths, opts \\ []) when is_list(file_paths) do
    incremental = Keyword.get(opts, :incremental, true)
    force_refresh = Keyword.get(opts, :force_refresh, false)

    # Filter files based on incremental mode
    {files_to_analyze, skipped_files} =
      if incremental and not force_refresh do
        filter_changed_files(file_paths)
      else
        {file_paths, []}
      end

    results =
      files_to_analyze
      |> Task.async_stream(&analyze_and_store_file/1, max_concurrency: System.schedulers_online())
      |> Enum.to_list()
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:task_exit, reason}}
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    error_count = Enum.count(results, &match?({:error, _}, &1))
    skipped_count = length(skipped_files)

    errors =
      results
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, {file, reason}} -> %{file: file, reason: reason} end)

    {:ok,
     %{
       total: length(file_paths),
       analyzed: length(files_to_analyze),
       skipped: skipped_count,
       success: success_count,
       errors: error_count,
       error_details: errors,
       graph_stats: Store.stats()
     }}
  end

  # Private functions

  defp find_supported_files(path, max_depth, exclude_patterns) do
    find_files_recursive(path, 0, max_depth, exclude_patterns, [])
  end

  defp find_files_recursive(_path, depth, max_depth, _exclude, acc) when depth > max_depth do
    acc
  end

  defp find_files_recursive(path, depth, max_depth, exclude_patterns, acc) do
    if should_exclude?(path, exclude_patterns) do
      acc
    else
      case File.ls(path) do
        {:ok, entries} ->
          Enum.reduce(entries, acc, fn entry, acc_inner ->
            full_path = Path.join(path, entry)

            cond do
              should_exclude?(full_path, exclude_patterns) ->
                acc_inner

              File.dir?(full_path) ->
                find_files_recursive(full_path, depth + 1, max_depth, exclude_patterns, acc_inner)

              is_supported_file?(full_path) ->
                [full_path | acc_inner]

              true ->
                acc_inner
            end
          end)

        {:error, _reason} ->
          acc
      end
    end
  end

  defp should_exclude?(path, patterns) do
    basename = Path.basename(path)

    Enum.any?(patterns, fn pattern ->
      String.contains?(path, pattern) or String.starts_with?(basename, ".")
    end)
  end

  defp is_supported_file?(path) do
    ext = Path.extname(path)

    ext in (ElixirAnalyzer.supported_extensions() ++
              ErlangAnalyzer.supported_extensions() ++
              PythonAnalyzer.supported_extensions() ++
              JavaScriptAnalyzer.supported_extensions())
  end

  defp filter_changed_files(file_paths) do
    file_paths
    |> Enum.split_with(fn file_path ->
      case FileTracker.has_changed?(file_path) do
        # New file, needs analysis
        {:new, _} -> true
        # Changed file, needs re-analysis
        {:changed, _} -> true
        # Deleted file, skip
        {:deleted, _} -> false
        # Unchanged, skip
        {:unchanged, _} -> false
      end
    end)
  end

  defp analyze_and_store_file(file_path) do
    case analyze_file(file_path) do
      {:ok, analysis} ->
        store_analysis(analysis)
        # Track file after successful analysis
        FileTracker.track_file(file_path, analysis)
        {:ok, %{file: file_path, status: :success}}

      {:error, reason} ->
        {:error, {file_path, reason}}
    end
  end

  defp analyze_file(file_path) do
    ext = Path.extname(file_path)

    analyzer =
      case ext do
        ext when ext in [".ex", ".exs"] -> ElixirAnalyzer
        ext when ext in [".erl", ".hrl"] -> ErlangAnalyzer
        ".py" -> PythonAnalyzer
        ext when ext in [".js", ".jsx", ".ts", ".tsx", ".mjs"] -> JavaScriptAnalyzer
        _ -> nil
      end

    if analyzer do
      case File.read(file_path) do
        {:ok, content} ->
          analyzer.analyze(content, file_path)

        {:error, reason} ->
          {:error, {:file_read_error, reason}}
      end
    else
      {:error, :unsupported_file_type}
    end
  end

  defp store_analysis(%{modules: modules, functions: functions, calls: calls, imports: imports}) do
    # Store modules
    Enum.each(modules, fn module ->
      Store.add_node(:module, module.name, module)
    end)

    # Store functions
    Enum.each(functions, fn func ->
      Store.add_node(:function, {func.module, func.name, func.arity}, func)
      # Add edge from module to function
      Store.add_edge(
        {:module, func.module},
        {:function, func.module, func.name, func.arity},
        :defines
      )
    end)

    # Store call relationships
    Enum.each(calls, fn call ->
      Store.add_edge(
        {:function, call.from_module, call.from_function, call.from_arity},
        {:function, call.to_module, call.to_function, call.to_arity},
        :calls
      )
    end)

    # Store imports
    Enum.each(imports, fn import ->
      Store.add_edge({:module, import.from_module}, {:module, import.to_module}, :imports)
    end)
  end

  defp default_exclude_patterns do
    [
      "node_modules",
      ".git",
      ".hg",
      ".svn",
      "_build",
      "deps",
      "target",
      "dist",
      "build",
      "coverage",
      ".elixir_ls",
      "__pycache__",
      ".pytest_cache",
      ".mypy_cache"
    ]
  end
end
