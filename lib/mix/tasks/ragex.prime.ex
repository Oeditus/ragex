defmodule Mix.Tasks.Ragex.Prime do
  @shortdoc "Pre-indexes and primes caches for fast editor startup"
  @moduledoc """
  Pre-indexes and primes embeddings, SCIP, knowledge graph, and `.ragex/dllb.redb` caches
  for a project outside of your editor.

  ## Usage

      mix ragex.prime [options]
      bin/ragex-prime [options]

  ## Options

      --path PATH      Directory to prime (default: current directory)
      --project PATH   Alias for --path
      --full           Perform full re-indexing (ignore existing content hashes)
      --daemon         Ensure background MCP daemon remains active after priming (default: true)
      --no-daemon      Disable starting a background daemon
      --status         Show status of daemon and project cache
      --stop           Stop the background daemon for the target project

  ## Examples

      # Pre-index current project and leave daemon running for editor
      $ mix ragex.prime

      # Full re-indexing for a specific project
      $ mix ragex.prime --project /path/to/my_project --full

      # Check priming and daemon status
      $ mix ragex.prime --status

      # Stop background daemon
      $ mix ragex.prime --stop
  """

  use Mix.Task

  alias Ragex.Analyzers.Directory
  alias Ragex.CLI.{Colors, Output, Progress}
  alias Ragex.Embeddings.Persistence
  alias Ragex.Graph.Store
  alias Ragex.MCP.Client
  alias Ragex.MCP.SocketPath

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          path: :string,
          project: :string,
          full: :boolean,
          daemon: :boolean,
          status: :boolean,
          stop: :boolean
        ]
      )

    path = Keyword.get(opts, :project) || Keyword.get(opts, :path) || File.cwd!()
    path = Path.expand(path)
    full_mode = Keyword.get(opts, :full, false)
    daemon_mode = Keyword.get(opts, :daemon, true)
    show_status = Keyword.get(opts, :status, false)
    stop_daemon = Keyword.get(opts, :stop, false)

    cond do
      stop_daemon ->
        do_stop(path)

      show_status ->
        do_status(path)

      true ->
        do_prime(path, full_mode, daemon_mode)
    end
  end

  defp do_stop(path) do
    System.put_env("RAGEX_PROJECT", path)
    socket_str = SocketPath.compute_string()

    Output.section("Stopping Ragex Daemon")
    Output.key_value([{"Project", path}, {"Socket", socket_str}])

    if Client.server_running?() do
      case Client.connect() do
        {:ok, conn} ->
          Client.disconnect(conn)

          case System.cmd("fuser", ["-k", socket_str], stderr_to_stdout: true) do
            {_, 0} ->
              IO.puts(Colors.success("✓ Stopped daemon process listening on #{socket_str}"))

            _ ->
              IO.puts(Colors.warning("Sent disconnect signal to daemon on #{socket_str}"))
          end

        {:error, reason} ->
          IO.puts(Colors.error("Failed to connect to daemon: #{inspect(reason)}"))
      end
    else
      IO.puts(Colors.muted("No active server listening on #{socket_str}"))
    end
  end

  defp do_status(path) do
    System.put_env("RAGEX_PROJECT", path)
    socket_str = SocketPath.compute_string()

    Output.section("Ragex Prime Status")

    running? = Client.server_running?()

    status_text =
      if running?,
        do: Colors.success("Active (listening)"),
        else: Colors.muted("Inactive (no server process)")

    Output.key_value([
      {"Project Path", path},
      {"Socket Path", socket_str},
      {"Daemon Status", status_text}
    ])

    IO.puts("")

    if running? do
      case Client.connect() do
        {:ok, conn} ->
          case Client.call_tool(conn, "graph_stats", %{}) do
            {:ok, data} ->
              nodes = Map.get(data, "node_count") || Map.get(data, "nodes") || 0
              edges = Map.get(data, "edge_count") || Map.get(data, "edges") || 0
              embeddings = Map.get(data, "embedding_count") || Map.get(data, "embeddings") || 0

              Output.key_value(
                [
                  {"Graph Nodes", Colors.highlight(to_string(nodes))},
                  {"Graph Edges", Colors.highlight(to_string(edges))},
                  {"Vector Embeddings", Colors.highlight(to_string(embeddings))}
                ],
                indent: 2
              )

            _ ->
              IO.puts(Colors.warning("Connected to daemon, but graph_stats returned no data."))
          end

          Client.disconnect(conn)

        {:error, _} ->
          :ok
      end
    else
      case Persistence.stats() do
        {:ok, pstats} ->
          Output.key_value(
            [
              {"Disk Cache", Colors.success("Present")},
              {"Cache Size", format_bytes(pstats.file_size)},
              {"Model", pstats.metadata.model_id}
            ],
            indent: 2
          )

        _ ->
          IO.puts(Colors.warning("No persisted cache found for this project."))
      end
    end
  end

  defp do_prime(path, full_mode, daemon_mode) do
    System.put_env("RAGEX_PROJECT", path)
    socket_str = SocketPath.compute_string()

    Output.section("Ragex Project Priming & Pre-indexing")

    mode_label =
      if full_mode, do: Colors.warning("Full Re-index"), else: Colors.info("Incremental")

    Output.key_value([
      {"Target Path", path},
      {"Socket Path", socket_str},
      {"Analysis Mode", mode_label}
    ])

    IO.puts("")

    start_time = System.monotonic_time(:millisecond)

    if Client.server_running?() do
      IO.puts(Colors.info("Found active Ragex daemon running on Unix socket."))
      IO.puts(Colors.info("Delegating indexing task to running daemon..."))

      case Client.connect() do
        {:ok, conn} ->
          spinner = Progress.spinner(label: "Priming project index via daemon...")

          # No fixed ceiling here: a first-time full index of a large
          # monorepo has no reasonable one-size-fits-all time bound, and the
          # daemon no longer races its own auto-analyze against this call
          # (see bin/ragex-prime), so this is expected to complete in one
          # indexing pass however long that legitimately takes.
          case Client.call_tool(
                 conn,
                 "analyze_directory",
                 %{
                   "path" => path,
                   "force_refresh" => full_mode
                 },
                 :infinity
               ) do
            {:ok, summary} ->
              Progress.stop_spinner(
                spinner,
                Colors.success("✓ Pre-indexing completed by daemon!")
              )

              end_time = System.monotonic_time(:millisecond)
              display_prime_summary(summary, end_time - start_time, socket_str, true)

            {:error, reason} ->
              Progress.stop_spinner(spinner, Colors.error("✗ Failed"))
              IO.puts(Colors.error("Daemon indexing failed: #{inspect(reason)}"))
          end

          Client.disconnect(conn)

        {:error, reason} ->
          IO.puts(Colors.error("Failed to connect to daemon: #{inspect(reason)}"))
      end
    else
      IO.puts(Colors.info("No running daemon found. Initializing local priming engine..."))

      Application.put_env(:ragex, :skip_bumblebee, false)
      Mix.Task.run("app.start")

      spinner = Progress.spinner(label: "Analyzing files, SCIP, and generating embeddings...")

      case Directory.analyze_directory(path,
             incremental: not full_mode,
             force_refresh: full_mode,
             load_project: true
           ) do
        {:ok, summary} ->
          Progress.stop_spinner(spinner, Colors.success("✓ Local indexing complete!"))

          save_spinner =
            Progress.spinner(label: "Persisting knowledge graph and embeddings cache to disk...")

          Store.save_cache(path)
          Progress.stop_spinner(save_spinner, Colors.success("✓ Cache saved to .ragex/"))

          end_time = System.monotonic_time(:millisecond)
          display_prime_summary(summary, end_time - start_time, socket_str, daemon_mode)

        {:error, reason} ->
          Progress.stop_spinner(spinner, Colors.error("✗ Failed"))
          IO.puts(Colors.error("Local indexing failed: #{inspect(reason)}"))
      end
    end
  end

  defp display_prime_summary(summary, duration_ms, socket_str, daemon_active?) do
    duration_sec = Float.round(duration_ms / 1000, 2)

    analyzed =
      Map.get(summary, :analyzed) || Map.get(summary, "analyzed") || Map.get(summary, :total) ||
        Map.get(summary, "total") || 0

    skipped = Map.get(summary, :skipped) || Map.get(summary, "skipped") || 0
    total = Map.get(summary, :total) || Map.get(summary, "total") || analyzed + skipped

    IO.puts("\n" <> Colors.bold("Priming Summary:"))

    Output.key_value(
      [
        {"Total Files", total},
        {"Files Analyzed", Colors.highlight(to_string(analyzed))},
        {"Files Skipped", Colors.muted(to_string(skipped))},
        {"Duration", "#{duration_sec}s"}
      ],
      indent: 2
    )

    stats = Store.stats()

    Output.key_value(
      [
        {"Knowledge Graph", "#{stats.nodes} nodes, #{stats.edges} edges"},
        {"Embeddings Stored", "#{stats.embeddings} vectors"}
      ],
      indent: 2
    )

    IO.puts("")

    if daemon_active? do
      IO.puts(Colors.success("✓ Ragex is fully primed and daemon is listening at #{socket_str}"))

      IO.puts(
        Colors.bold(
          "  You can now start your editor (`nvim .`). Neovim will connect instantly (<5ms)!"
        )
      )
    else
      IO.puts(Colors.success("✓ Ragex is fully primed and saved to disk cache (.ragex/)"))

      IO.puts(Colors.bold("  Starting your editor will load pre-built caches instantly!"))
    end

    IO.puts("")
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
end
