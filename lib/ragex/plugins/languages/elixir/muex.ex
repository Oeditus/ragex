defmodule Ragex.Plugins.Languages.Elixir.Muex do
  @moduledoc """
  Bridge to [Muex](https://hexdocs.pm/muex), a mutation-testing runner for
  Elixir and Erlang.

  Mutation testing answers a question coverage cannot: *would the test suite
  notice if this line were wrong?* Muex introduces deliberate defects
  (mutations) into the source, runs the suite against each one, and reports how
  many the tests caught. Surviving mutants are lines that are executed but not
  asserted on -- the concrete, enumerable form of "our coverage is a lie".

  ## Optional dependency

  Muex is not a Ragex dependency. `available?/1` probes for it and `run/1`
  degrades to an actionable error when it is missing, mirroring
  `Ragex.Plugins.Languages.Elixir.Propwise` and `Ragex.Analysis.Prisma`. The tool
  is still advertised -- a user who has Muex installed must be able to find it
  -- but the error message names the exact `mix.exs` line to add.

  ## Why the probe is process-local and the run is not

  `available?/1` is a process-local `Code.ensure_loaded?/1` check: it can only
  see dependencies of the *Ragex* VM. That is the right question for
  `available?/1` (it decides whether advertising the tool is honest), but it is
  the wrong question for `run/1`: mutation testing is meaningful precisely for
  projects that have Muex as a *dev/test* dependency, which Ragex will not have
  loaded. `run/1` therefore does not require the module in-process. It shells
  out to `mix muex` inside the analysed project, which is the supported way to
  run it and the only way that works when Muex is a dependency of the analysed
  project rather than of Ragex.

  ## What is reported

  Muex's own `--format json` report is parsed and summarized. The mutation
  score is passed through verbatim as `score_low`/`score_high`:

    * `score_low` assumes every timed-out mutant survived (pessimistic)
    * `score_high` assumes every timed-out mutant was killed (optimistic)

  They differ only when the run timed out, so a single number would be a lie in
  exactly the case the reader most needs to know about. Equivalent and
  no-coverage mutants are excluded from the score by Muex, and are reported as
  their own counts rather than folded into "survived".
  """

  @type mutation_result :: %{
          required(:status) => String.t(),
          optional(:file) => String.t() | nil,
          optional(:line) => integer() | nil,
          optional(:mutator) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:original) => String.t() | nil,
          optional(:mutated) => String.t() | nil
        }

  @default_timeout 900_000

  @doc "Returns the MCP tool schema for `muex_analyze`."
  @spec tool_schema() :: Ragex.Plugin.tool_schema()
  def tool_schema do
    %{
      name: "muex_analyze",
      description:
        "Run mutation testing (Muex) to measure whether the test suite actually asserts on " <>
          "the code it covers. Introduces deliberate defects into the source, runs the suite " <>
          "against each, and reports which mutants survived -- i.e. which lines are executed " <>
          "but not verified. Surviving mutants are concrete gaps to add assertions for. " <>
          "NOTE: this runs the project's full test suite once per mutant and can take minutes; " <>
          "use `max_mutations`, `since`, or `optimize_level` to bound it. " <>
          "`score_low` assumes timed-out mutants survived and `score_high` assumes they were " <>
          "killed; they differ only when the run timed out.",
      inputSchema: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Project root directory (must contain mix.exs)",
            default: "."
          },
          files: %{
            type: "string",
            description:
              "Comma-separated source directories, files, or glob patterns to mutate " <>
                "(default: \"lib\")",
            default: "lib"
          },
          test_paths: %{
            type: "string",
            description: "Comma-separated test directories, files, or glob patterns",
            default: "test"
          },
          language: %{
            type: "string",
            description: "Language adapter",
            enum: ["elixir", "erlang"],
            default: "elixir"
          },
          mutators: %{
            type: "string",
            description:
              "Comma-separated mutator names (e.g. \"arithmetic,comparison,boolean\"). " <>
                "Omit for Muex's full set."
          },
          optimize_level: %{
            type: "string",
            description:
              "Mutation reduction preset. conservative keeps <1% score impact and is the " <>
                "right choice for CI; balanced is for development iteration; aggressive is " <>
                "for a quick smoke check only.",
            enum: ["conservative", "balanced", "aggressive"],
            default: "conservative"
          },
          max_mutations: %{
            type: "integer",
            description: "Cap the total number of mutants tested; 0 = unlimited",
            default: 0
          },
          since: %{
            type: "string",
            description:
              "Only mutate lines changed since this git ref (e.g. \"main\"), using PR " <>
                "semantics. Ideal for reviewing a branch without a full run."
          },
          coverage_guided: %{
            type: "boolean",
            description:
              "Run only the tests covering each mutated line; uncovered lines are reported " <>
                "as \"no coverage\" instead of consuming a full test run",
            default: false
          },
          fail_at: %{
            type: "number",
            description: "Mutation score percentage below which the run is reported as failing",
            default: 80
          },
          concurrency: %{
            type: "integer",
            description: "Number of parallel workers (default: number of schedulers)"
          },
          timeout: %{
            type: "integer",
            description: "Per-mutant test timeout in milliseconds",
            default: 10_000
          },
          deadline_minutes: %{
            type: "number",
            description:
              "Stop starting new mutants this many minutes after the first one starts. " <>
                "Mutants already running finish and the report is marked partial."
          },
          run_timeout: %{
            type: "integer",
            description:
              "Overall wall-clock limit for the whole run in milliseconds (default: 15 " <>
                "minutes). Distinct from `timeout`, which bounds one mutant's test run.",
            default: 900_000
          },
          format: %{
            type: "string",
            description: "Output verbosity",
            enum: ["summary", "detailed", "survivors"],
            default: "summary"
          }
        },
        required: ["path"]
      },
      destruction_level: :none
    }
  end

  @doc """
  Returns whether Muex is loadable in the Ragex VM.

  This is a process-local probe and says nothing about whether the *analysed
  project* has Muex -- see the module docs. It exists so the registry can be
  honest about advertising the tool.
  """
  @spec available?(String.t()) :: boolean()
  def available?(_path \\ "."), do: Code.ensure_loaded?(Module.concat([Muex]))

  @doc """
  Runs `mix muex` in the analysed project and returns normalized findings.

  ## Formats

    * `"summary"` -- counts and score only, no per-mutant payload
    * `"detailed"` -- counts, score, and every mutant result
    * `"survivors"` -- only the mutants the tests failed to catch

  ## Return values

    * `{:ok, report}` -- the run completed. A score below `fail_at` is still a
      successful analysis; it is reported in `passed` rather than as an error,
      because "your tests are weak" is a finding, not a failure of the tool.
    * `{:error, reason}` -- Muex is missing, the project is not a Mix project,
      the run crashed, or the report could not be parsed.
  """
  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(%{"path" => path} = params) when is_binary(path) do
    project_root = Path.expand(path)

    with :ok <- ensure_mix_project(project_root),
         {:ok, output} <- invoke(project_root, params),
         {:ok, report} <- parse(output) do
      format(report, Map.get(params, "format", "summary"), params)
    end
  end

  def run(_params), do: {:error, "muex_analyze requires a \"path\" argument"}

  # ----- Guards --------------------------------------------------------------

  defp ensure_mix_project(project_root) do
    if File.regular?(Path.join(project_root, "mix.exs")) do
      :ok
    else
      {:error,
       "muex_analyze needs a Mix project: no mix.exs in #{project_root}. " <>
         "Point \"path\" at the project root (the directory containing mix.exs)."}
    end
  end

  # ----- Invocation ----------------------------------------------------------

  # Shells out rather than calling `Muex.run/1` directly: Muex is a dev/test
  # dependency of the *analysed* project, so it is normally absent from the
  # Ragex VM, and `mix muex` is the supported entry point regardless.
  #
  # The timeout bounds the whole run, not one mutant (`--timeout` does that). A
  # mutation run executes the suite once per mutant, so the default is
  # deliberately generous; a project that needs longer can raise it via the
  # `deadline_minutes` flag, which stops Muex cleanly and still reports.
  defp invoke(project_root, params) do
    args = ["muex", "--format", "json" | cli_args(params)]
    timeout = Map.get(params, "run_timeout", @default_timeout)

    task =
      Task.async(fn ->
        System.cmd("mix", args,
          cd: project_root,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      # Note the double unwrap: `Task.yield/2` returns `{:ok, task_result}`,
      # where the task result is itself `System.cmd/3`'s `{output, code}`. A
      # single-level pattern would bind `output` to the whole `{output, code}`
      # tuple and `code` to `:ok`, silently turning every failure into a
      # success.
      {:ok, {output, code}} when code in [0, 1] ->
        # Exit 1 legitimately means "score below --fail-at": a completed run
        # with a finding, not a crash. Ragex reports the score itself.
        {:ok, output}

      {:ok, {output, code}} ->
        {:error, {:exit, code, truncate(output)}}

      {:exit, reason} ->
        {:error, {:task_exit, reason}}

      nil ->
        {:error,
         "muex_analyze timed out after #{div(timeout, 60_000)} minute(s). " <>
           "Narrow the run with `files`, `since`, `max_mutations`, or `deadline_minutes`."}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # Only flags the caller actually set are forwarded, so Muex's own defaults
  # apply for everything else. `--format json` is always ours: the report is
  # parsed, not printed.
  @doc false
  @spec cli_args(map()) :: [String.t()]
  def cli_args(params) do
    [
      {"files", "--files", &string_arg/1},
      {"test_paths", "--test-paths", &string_arg/1},
      {"language", "--language", &string_arg/1},
      {"mutators", "--mutators", &string_arg/1},
      {"optimize_level", "--optimize-level", &string_arg/1},
      {"since", "--since", &string_arg/1},
      {"max_mutations", "--max-mutations", &int_arg/1},
      {"fail_at", "--fail-at", &int_arg/1},
      {"concurrency", "--concurrency", &int_arg/1},
      {"timeout", "--timeout", &int_arg/1},
      {"deadline_minutes", "--deadline-minutes", &number_arg/1}
    ]
    |> Enum.flat_map(fn {key, flag, cast} ->
      case Map.fetch(params, key) do
        {:ok, value} when not is_nil(value) -> [flag, cast.(value)]
        _ -> []
      end
    end)
    |> maybe_flag(params, "coverage_guided", "--coverage-guided")
  end

  defp maybe_flag(args, params, key, flag) do
    if Map.get(params, key) == true, do: args ++ [flag], else: args
  end

  defp string_arg(value) when is_binary(value), do: value
  defp string_arg(value), do: to_string(value)

  defp int_arg(value) when is_integer(value), do: Integer.to_string(value)
  defp int_arg(value) when is_float(value), do: Integer.to_string(trunc(value))
  defp int_arg(value) when is_binary(value), do: value

  defp number_arg(value) when is_number(value), do: to_string(value)
  defp number_arg(value) when is_binary(value), do: value

  # ----- Parsing -------------------------------------------------------------

  # `mix muex --format json` prints the report to stdout, but `mix` may prefix
  # it with compilation or dependency warnings. The report is a JSON object, so
  # the payload starts at the first `{` and ends at the matching last `}`.
  #
  # `:binary` rather than `String` because this operates on raw bytes: the
  # output may contain invalid UTF-8 from a compiler error, and byte offsets are
  # what `binary_part/3` needs anyway.
  defp parse(output) when is_binary(output) do
    with {:ok, json} <- extract_json(output),
         {:ok, decoded} <- decode(json) do
      {:ok, normalize(decoded)}
    end
  end

  defp extract_json(output) do
    with {start, _} <- :binary.match(output, "{"),
         {stop, _} <- output |> :binary.matches("}") |> List.last(),
         true <- stop > start do
      {:ok, binary_part(output, start, stop - start + 1)}
    else
      _ -> {:error, {:no_report, truncate(output)}}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, other} -> {:error, {:invalid_report, other}}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp normalize(report) do
    results = Map.get(report, "results") || []

    %{
      total: length(results),
      counts: results |> Enum.frequencies_by(& &1["result"]) |> stringify_keys(),
      score_low: Map.get(report, "score_low", 0.0),
      score_high: Map.get(report, "score_high", 0.0),
      partial: Map.get(report, "partial"),
      mutations: Enum.map(results, &normalize_mutation/1)
    }
  end

  defp normalize_mutation(result) do
    mutation = Map.get(result, "mutation") || %{}

    %{
      status: Map.get(result, "result", "unknown"),
      file: Map.get(mutation, "file"),
      line: Map.get(mutation, "line"),
      mutator: mutation |> Map.get("mutator") |> mutator_name(),
      description: Map.get(mutation, "description"),
      original: Map.get(mutation, "original"),
      mutated: Map.get(mutation, "mutated")
    }
  end

  # Muex reports the mutator either as a bare name or as a module atom/string.
  defp mutator_name(nil), do: nil
  defp mutator_name(name) when is_binary(name), do: name
  defp mutator_name(module) when is_atom(module), do: module |> Module.split() |> List.last()

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  # ----- Formatting ----------------------------------------------------------

  defp format(data, "summary", params) do
    {:ok,
     %{
       status: "success",
       source: "muex",
       total_mutants: data.total,
       killed: count(data, "killed"),
       survived: count(data, "survived"),
       timeout: count(data, "timeout"),
       invalid: count(data, "invalid"),
       equivalent: count(data, "equivalent"),
       no_coverage: count(data, "no_coverage"),
       score_low: data.score_low,
       score_high: data.score_high,
       passed: passed?(data, params),
       partial: data.partial,
       survivors_count: count(data, "survived")
     }}
  end

  defp format(data, "detailed", params) do
    {:ok,
     %{
       status: "success",
       source: "muex",
       total_mutants: data.total,
       counts: data.counts,
       score_low: data.score_low,
       score_high: data.score_high,
       passed: passed?(data, params),
       partial: data.partial,
       mutations: data.mutations
     }}
  end

  defp format(data, "survivors", params) do
    {:ok,
     %{
       status: "success",
       source: "muex",
       score_low: data.score_low,
       score_high: data.score_high,
       passed: passed?(data, params),
       partial: data.partial,
       survivors: Enum.filter(data.mutations, &(&1.status == "survived"))
     }}
  end

  defp format(_data, other, _params), do: {:error, "Unknown format: #{inspect(other)}"}

  defp count(data, status), do: Map.get(data.counts, status, 0)

  defp passed?(data, params) do
    fail_at = Map.get(params, "fail_at", 80)
    data.score_low >= fail_at
  end

  defp truncate(output) when is_binary(output) do
    if String.length(output) > 2_000, do: String.slice(output, 0, 2_000) <> "...", else: output
  end

  defp truncate(other), do: other
end
