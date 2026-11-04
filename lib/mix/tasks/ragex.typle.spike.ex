defmodule Mix.Tasks.Ragex.Typle.Spike do
  @shortdoc "Measures Typle's usefulness on this codebase (dynamic() ratio, crash rate)"

  @moduledoc """
  Runs the Typle viability spike against a directory of Elixir sources.

      mix ragex.typle.spike
      mix ragex.typle.spike lib --limit 100

  Reports, for the sampled files:

    * how many files Typle could analyze at all (it raises on some real-world
      syntax -- notably struct updates, `%{struct | key: value}`),
    * how many expressions it inferred,
    * what share of those came back as `dynamic()`, i.e. "no idea".

  The second number is the one that decides whether type inference is worth
  surfacing as a graph property: Typle honestly returns `dynamic()` when it
  cannot infer, so a high ratio means the feature would add noise rather than
  signal.

  Re-run this after any Typle upgrade to see whether the numbers moved.
  """

  use Mix.Task

  @switches [limit: :integer, path: :string]

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches)

    root = opts[:path] || List.first(positional) || "lib"
    limit = opts[:limit]

    files =
      root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> maybe_limit(limit)

    if files == [] do
      Mix.shell().error("No .ex files found under #{root}")
    else
      report(files, root)
    end
  end

  defp report(files, root) do
    results = Enum.map(files, &analyze/1)

    total = length(results)
    ok = Enum.count(results, &match?({:ok, _, _}, &1))
    failed = total - ok

    {exprs, dynamic} =
      results
      |> Enum.flat_map(fn
        {:ok, _file, stats} -> [stats]
        _ -> []
      end)
      |> Enum.reduce({0, 0}, fn {e, d}, {ae, ad} -> {ae + e, ad + d} end)

    shell = Mix.shell()

    shell.info("")
    shell.info("Typle spike -- #{root}")
    shell.info(String.duplicate("=", 60))
    shell.info("files sampled     : #{total}")
    shell.info("analyzed ok       : #{ok}")
    shell.info("failed (raised)   : #{failed}#{pct(failed, total)}")
    shell.info("expressions       : #{exprs}")
    shell.info("dynamic()         : #{dynamic}#{pct(dynamic, exprs)}")
    shell.info("")

    shell.info("Sample failures:")

    results
    |> Enum.flat_map(fn
      {:error, file, reason} -> [{file, reason}]
      _ -> []
    end)
    |> Enum.take(5)
    |> Enum.each(fn {file, reason} ->
      shell.info("  #{file}")
      shell.info("    #{String.slice(reason, 0, 110)}")
    end)

    shell.info("")
    verdict(dynamic, exprs)
  end

  defp verdict(_dynamic, 0) do
    Mix.shell().info("Verdict: no expressions inferred -- Typle is not usable here.")
  end

  defp verdict(dynamic, exprs) do
    ratio = dynamic / exprs

    Mix.shell().info(
      "Verdict: #{Float.round(ratio * 100, 1)}% of inferred expressions are dynamic()."
    )

    cond do
      ratio > 0.7 ->
        Mix.shell().info("  Too noisy to surface as a graph property. Keep type inference off.")

      ratio > 0.4 ->
        Mix.shell().info("  Marginal. Worth a targeted use (e.g. dead-code proof) only.")

      true ->
        Mix.shell().info(
          "  Good signal. Consider enabling `config :ragex, type_inference: :enabled`."
        )
    end
  end

  defp analyze(file) do
    case Typle.types_for_file(file) do
      {:ok, map} ->
        n = map_size(map)
        d = map |> Enum.count(fn {_pos, v} -> dynamic_value?(v) end)
        {:ok, file, {n, d}}

      {:error, reason} ->
        {:error, file, inspect(reason)}
    end
  rescue
    e -> {:error, file, Exception.message(e)}
  catch
    kind, reason -> {:error, file, inspect({kind, reason})}
  end

  defp dynamic_value?(%{type: type}), do: dynamic_value?(type)
  defp dynamic_value?(nil), do: false
  defp dynamic_value?(%{dynamic?: true}), do: true
  defp dynamic_value?(type), do: inspect(type) |> String.contains?("dynamic(")

  defp maybe_limit(files, nil), do: files
  defp maybe_limit(files, limit) when is_integer(limit), do: Enum.take(files, limit)

  defp pct(_n, 0), do: ""
  defp pct(n, d), do: "  (#{Float.round(n / d * 100, 1)}%)"
end
