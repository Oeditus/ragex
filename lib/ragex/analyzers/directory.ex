defmodule Ragex.Analyzers.Directory do
  @moduledoc """
  Analyzes entire directories recursively, detecting and analyzing files
  based on their extensions.

  This module provides batch analysis capabilities for entire projects.
  """

  alias Ragex.Analyzers.Metastatic, as: MetastaticAnalyzer
  alias Ragex.CLI.Progress
  alias Ragex.Embeddings.{FileTracker, Helper}
  alias Ragex.Graph.Store
  alias Ragex.MCP.Server

  require Logger

  @doc """
  Analyzes all supported files in a directory recursively.

  Returns a summary of analyzed files and any errors encountered.

  ## Options

  - `:max_depth` - Maximum directory depth (default: 10)
  - `:exclude_patterns` - Patterns to exclude (default: common build dirs)
  - `:incremental` - Enable incremental updates (default: true)
  - `:force_refresh` - Force full refresh even if unchanged (default: false)
  - `:notify` - Send MCP progress notifications (default: true)
  - `:timeout` - Per-file analysis timeout in ms (default: 300_000 = 5 min)
  - `:max_concurrency` - Max parallel file analyses (default: 4)
  - `:load_project` - Switch the store to `path` as the active project,
    clearing previously loaded graph data first (default: true). Pass
    `false` when batch-analyzing several independent directories that
    should accumulate into the same graph instead of replacing each other
    (e.g. `:auto_analyze_dirs`).
  """
  @spec analyze_directory(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def analyze_directory(path, opts \\ []) do
    if Keyword.get(opts, :load_project, true) do
      Store.load_project(path)
    end

    max_depth = Keyword.get(opts, :max_depth, 10)
    exclude_patterns = Keyword.get(opts, :exclude_patterns, default_exclude_patterns())
    incremental = Keyword.get(opts, :incremental, true)
    force_refresh = Keyword.get(opts, :force_refresh, false)
    notify = Keyword.get(opts, :notify, true)
    timeout = Keyword.get(opts, :timeout, 300_000)
    max_concurrency = Keyword.get(opts, :max_concurrency, 4)
    watch = Keyword.get(opts, :watch, true)

    if watch and File.dir?(path) do
      Ragex.Watcher.watch_directory(path)
    end

    result =
      case File.stat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          if notify do
            notify_progress("analysis_scanning", %{stage: "scanning_directory", path: path})
          end

          if Application.get_env(:ragex, :enable_auto_scip, true) do
            if notify do
              notify_progress("analysis_scip", %{stage: "scip_indexing", path: path})
            end
            auto_index_scip(path)
          end

          files = find_supported_files(path, max_depth, exclude_patterns)

          analyze_files(files,
            incremental: incremental,
            force_refresh: force_refresh,
            notify: notify,
            timeout: timeout,
            max_concurrency: max_concurrency
          )

        {:ok, %File.Stat{type: :regular}} ->
          # Single file provided
          analyze_files([path],
            incremental: incremental,
            force_refresh: force_refresh,
            notify: notify,
            timeout: timeout,
            max_concurrency: max_concurrency
          )

        {:error, reason} ->
          {:error, {:file_error, reason}}
      end

    case result do
      {:ok, _} ->
        Store.save_cache(path)
        result

      _ ->
        result
    end
  end

  @doc """
  Analyzes multiple files and stores results in the graph.

  ## Options

  - `:incremental` - Skip unchanged files (default: true)
  - `:force_refresh` - Force analysis even if unchanged (default: false)
  - `:notify` - Send MCP progress notifications (default: true)
  - `:timeout` - Per-file analysis timeout in ms (default: 300_000 = 5 min)
  - `:max_concurrency` - Max parallel file analyses (default: 4)
  """
  @spec analyze_files([String.t()], keyword()) :: {:ok, map()}
  def analyze_files(file_paths, opts \\ []) when is_list(file_paths) do
    incremental = Keyword.get(opts, :incremental, true)
    force_refresh = Keyword.get(opts, :force_refresh, false)
    notify = Keyword.get(opts, :notify, true)
    timeout = Keyword.get(opts, :timeout, 300_000)
    max_concurrency = Keyword.get(opts, :max_concurrency, 4)

    # Filter out unsupported file types (e.g. markdown docs, binary assets)
    file_paths = Enum.filter(file_paths, &supported_file?/1)

    # Filter files based on incremental mode
    {files_to_analyze, skipped_files} =
      if incremental and not force_refresh do
        filter_changed_files(file_paths)
      else
        {file_paths, []}
      end

    if notify do
      notify_progress("analysis_start", %{
        total: length(file_paths),
        to_analyze: length(files_to_analyze),
        skipped: length(skipped_files)
      })
    end

    total_to_analyze = length(files_to_analyze)
    t0 = System.monotonic_time(:millisecond)

    Logger.info("Analyzing #{total_to_analyze} files (concurrency=#{max_concurrency})")

    results =
      files_to_analyze
      |> Task.async_stream(&analyze_and_store_file/1,
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Stream.with_index(1)
      |> Enum.map(fn
        {{:ok, {:ok, result}}, index} ->
          elapsed = div(System.monotonic_time(:millisecond) - t0, 1000)
          basename = Path.basename(result.file)

          Progress.bar(index, total_to_analyze,
            label: "#{basename} (#{elapsed}s)",
            width: 30
          )

          if notify do
            notify_progress("analysis_file", %{
              current: index,
              total: total_to_analyze,
              file: result.file,
              status: result.status
            })
          end

          {:ok, result}

        {{:ok, {:error, {file, reason}}}, index} ->
          elapsed = div(System.monotonic_time(:millisecond) - t0, 1000)
          basename = Path.basename(file)
          short_reason = reason |> inspect() |> String.slice(0, 60)

          Progress.bar(index, total_to_analyze,
            label: "FAIL #{basename} (#{elapsed}s)",
            width: 30
          )

          Logger.warning("[#{index}/#{total_to_analyze}] #{basename}: #{short_reason}")
          {:error, {file, reason}}

        {{:exit, reason}, index} ->
          elapsed = div(System.monotonic_time(:millisecond) - t0, 1000)

          Progress.bar(index, total_to_analyze,
            label: "TIMEOUT (#{elapsed}s)",
            width: 30
          )

          Logger.warning("[#{index}/#{total_to_analyze}] TIMEOUT: #{inspect(reason)}")
          {:error, {:task_exit, reason}}
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    error_count = Enum.count(results, &match?({:error, _}, &1))
    skipped_count = length(skipped_files)

    errors =
      results
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn
        {:error, {:task_exit, reason}} -> %{file: "unknown", reason: {:task_exit, reason}}
        {:error, {file, reason}} -> %{file: file, reason: reason}
      end)

    if notify do
      notify_progress("analysis_complete", %{
        total: length(file_paths),
        analyzed: length(files_to_analyze),
        success: success_count,
        errors: error_count
      })
    end

    if success_count > 0 do
      Store.save_cache()
    end

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
    find_files_recursive(path, 0, max_depth, exclude_patterns, [], path)
  end

  defp find_files_recursive(_path, depth, max_depth, _exclude, acc, _root)
       when depth > max_depth do
    acc
  end

  defp find_files_recursive(path, depth, max_depth, exclude_patterns, acc, root_path) do
    if should_exclude?(path, exclude_patterns, root_path) do
      acc
    else
      case File.ls(path) do
        {:ok, entries} ->
          Enum.reduce(entries, acc, fn entry, acc_inner ->
            full_path = Path.join(path, entry)

            cond do
              should_exclude?(full_path, exclude_patterns, root_path) ->
                acc_inner

              File.dir?(full_path) ->
                find_files_recursive(
                  full_path,
                  depth + 1,
                  max_depth,
                  exclude_patterns,
                  acc_inner,
                  root_path
                )

              supported_file?(full_path) ->
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

  defp should_exclude?(path, patterns, root_path) do
    basename = Path.basename(path)

    if basename in patterns or
         (String.starts_with?(basename, ".") and basename not in [".", ".."]) do
      true
    else
      rel_path = if root_path, do: Path.relative_to(path, root_path), else: path
      segments = Path.split(rel_path)

      Enum.any?(segments, fn segment ->
        segment in patterns or
          (String.starts_with?(segment, ".") and segment not in [".", ".."])
      end)
    end
  end

  defp supported_file?(path) do
    Path.extname(path) in Ragex.LanguageSupport.supported_extensions()
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

        # Build entity-body pairs so we can diff against stored hashes.
        entity_pairs = build_entity_pairs(analysis)

        # Only re-embed entities whose body text has changed since last run.
        stale = FileTracker.stale_entities_for_file(file_path, entity_pairs)

        embed_opts =
          if MapSet.size(stale) == length(entity_pairs) do
            # All entities are new/changed — skip the filter for a simpler path
            []
          else
            [only: stale]
          end

        case Helper.generate_and_store_embeddings(analysis, embed_opts) do
          :ok ->
            # Persist the new hashes so unchanged functions are skipped next time
            FileTracker.record_entity_hashes(file_path, entity_pairs)

          {:error, _reason} ->
            :ok
        end

        FileTracker.track_file(file_path, analysis)
        {:ok, %{file: file_path, status: :success}}

      {:error, reason} ->
        {:error, {file_path, reason}}
    end
  end

  # Build {entity_id, body_text} pairs for all modules and functions so we can
  # hash their bodies and detect per-function changes between analysis runs.
  defp build_entity_pairs(%{modules: modules, functions: functions}) do
    module_pairs =
      Enum.map(modules, fn mod ->
        {mod.name, mod[:source] || mod[:doc] || inspect(mod.name)}
      end)

    function_pairs =
      Enum.map(functions, fn func ->
        id = {func.module, func.name, func.arity}
        body = func[:source] || func[:body] || func[:doc] || inspect(id)
        {id, body}
      end)

    module_pairs ++ function_pairs
  end

  defp analyze_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        content = sanitize_utf8(content)
        MetastaticAnalyzer.analyze(content, file_path)

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  # Ensures the binary is valid UTF-8. Files saved with legacy encodings
  # (e.g. Latin-1) contain bytes that are invalid UTF-8 and cause
  # `Code.string_to_quoted/2` to raise `UnicodeConversionError`.
  # We replace invalid byte sequences with the Unicode replacement character
  # (U+FFFD) so the parser can proceed without crashing.
  defp sanitize_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      Logger.debug("Sanitizing non-UTF-8 content (replacing invalid bytes)")

      binary
      |> :unicode.characters_to_binary(:utf8)
      |> case do
        result when is_binary(result) ->
          result

        {:error, good, _rest} ->
          # Partial conversion succeeded up to `good`; fall back to byte-by-byte
          sanitize_utf8_bytes(binary, good)

        {:incomplete, good, _rest} ->
          sanitize_utf8_bytes(binary, good)
      end
    end
  end

  defp sanitize_utf8_bytes(<<>>, acc), do: acc

  defp sanitize_utf8_bytes(<<c::utf8, rest::binary>>, acc) do
    sanitize_utf8_bytes(rest, <<acc::binary, c::utf8>>)
  end

  defp sanitize_utf8_bytes(<<_byte, rest::binary>>, acc) do
    # Replace invalid byte with U+FFFD REPLACEMENT CHARACTER
    sanitize_utf8_bytes(rest, <<acc::binary, 0xEF, 0xBF, 0xBD>>)
  end

  defp store_analysis(%{modules: modules, functions: functions, calls: calls, imports: imports}) do
    # Prepare node items
    module_nodes = Enum.map(modules, fn module -> {:module, module.name, module} end)

    function_nodes =
      Enum.map(functions, fn func ->
        {:function, {func.module, func.name, func.arity}, func}
      end)

    Store.add_nodes(module_nodes ++ function_nodes)

    # Prepare edge items
    define_edges =
      Enum.map(functions, fn func ->
        {
          {:module, func.module},
          {:function, func.module, func.name, func.arity},
          :defines,
          []
        }
      end)

    call_edges =
      Enum.map(calls, fn call ->
        {
          {:function, call.from_module, call.from_function, call.from_arity},
          {:function, call.to_module, call.to_function, call.to_arity},
          :calls,
          []
        }
      end)

    import_edges =
      Enum.map(imports, fn import ->
        {
          {:module, import.from_module},
          {:module, import.to_module},
          :imports,
          []
        }
      end)

    Store.add_edges(define_edges ++ call_edges ++ import_edges)
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
      ".mypy_cache",
      ".bundle",
      "vendor/bundle"
    ]
  end

  defp notify_progress(event, params) do
    # Send notification via MCP server if available
    if Process.whereis(Ragex.MCP.Server) do
      Server.send_notification("analyzer/progress", %{
        event: event,
        params: params,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end
  end

  defp auto_index_scip(project_dir) do
    alias Ragex.Analyzers.SCIP.{Adapter, Indexer, Parser}

    try do
      {:ok, results} = Indexer.index_all(project_dir)

      Enum.each(results, fn
        {lang, {:ok, json}} ->
          Logger.info("SCIP: Auto-indexing of #{lang} succeeded, ingesting...")

          case Parser.parse(json, project_dir) do
            {:ok, analysis} ->
              Adapter.ingest(analysis, generate_embeddings: true)

            {:error, err} ->
              Logger.warning("SCIP: Auto-parse failed for #{lang}: #{inspect(err)}")
          end

        {lang, {:error, reason}} ->
          Logger.debug("SCIP: Auto-indexing skipped/failed for #{lang}: #{inspect(reason)}")
      end)
    rescue
      e -> Logger.warning("SCIP: Auto-indexing failed: #{Exception.message(e)}")
    end
  end
end
