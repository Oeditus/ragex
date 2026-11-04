defmodule Ragex.Analysis.Prisma do
  @moduledoc """
  Bridge to [Prisma](https://prisma.hexdocs.pm), a hybrid success/gradual type
  analyzer for Erlang and Elixir.

  Prisma combines three analyses that Ragex cannot do from source alone:

    * **Discrepancy (success typing)** -- calls and clauses that provably cannot
      succeed, with zero false alarms on dynamically compatible code.
    * **Gradual typing** -- mismatches between a `@spec`/`-spec` contract and the
      types actually inferred for the body.
    * **Oxbow / dead code** -- unreachable clauses, impossible guards, unused
      private functions and ignored parameters.

  ## Why this shells out

  Prisma is an Erlang application that ships only a rebar3 plugin and two Mix
  tasks (`mix prisma`, `mix prisma.build`); it exposes **no library API**. Worse,
  its Mix task terminates the VM with `erlang:halt/1` when it finds errors, so it
  can never be linked into a long-running process such as the Ragex MCP server.
  Running it as a subprocess is therefore the only correct integration.

  ## Requirements

  Prisma analyzes **compiled beams** (`_build/*/ebin`) and needs a `.pplt`
  (Prisma Persistent Lookup Table) for the OTP/Elixir baseline. Run
  `mix prisma.build` once in the target project before invoking this module.
  When Prisma or the beams are unavailable, every function here returns
  `{:error, reason}` rather than raising -- callers are expected to treat this
  as an optional capability.

  ## Output

  Prisma is invoked with `--format json`, which emits a JSON array of findings:

      [
        {
          "kind": "gradual_mismatch",
          "severity": "error",
          "module": "MyApp.User",
          "function": "age",
          "arity": 1,
          "line": 12,
          "message": "...",
          "file": "lib/my_app/user.ex",
          "declared": "non_neg_integer()",
          "actual": "integer()"
        }
      ]

  `analyze/2` normalizes these into maps with atom keys and a `:source` field
  identifying the tool, so they can be merged with Ragex's own findings.
  """

  @type finding :: %{
          kind: String.t(),
          severity: :error | :warning | :note,
          module: String.t() | nil,
          function: String.t() | nil,
          arity: non_neg_integer() | nil,
          line: non_neg_integer() | nil,
          file: String.t() | nil,
          message: String.t(),
          declared: String.t() | nil,
          actual: String.t() | nil,
          expected: String.t() | nil,
          source: :prisma
        }

  @type mode :: :hybrid | :gradual | :discrepancy
  @type format :: :human | :oneline | :json

  @default_timeout 120_000

  @doc """
  Returns whether Prisma appears to be available for `project_root`.

  Checks for a `mix prisma` task in the project's dependency tree. This is a
  cheap heuristic: it does not verify that the beams or `.pplt` files exist,
  which only a real run can establish.
  """
  @spec available?(String.t()) :: boolean()
  def available?(project_root \\ ".") do
    prisma_dep?(project_root) or System.find_executable("prisma") != nil
  end

  @doc """
  Runs Prisma against `project_root` and returns normalized findings.

  ## Options

    * `:mode` -- `:hybrid` (default), `:gradual`, or `:discrepancy`.
    * `:format` -- `:json` (default), `:oneline`, or `:human`.
    * `:oxbow` -- include oxbow/dead-code analysis (default `true`).
    * `:warnings_as_errors` -- treat warnings as failures (default `false`).
    * `:timeout` -- subprocess timeout in ms (default `120_000`).
    * `:env` -- extra environment variables for the subprocess.

  ## Return values

    * `{:ok, findings}` -- the analysis ran. `findings` may be empty, which means
      Prisma proved the code clean. Prisma's own exit code is **not** treated as
      an error here: exit status 1 legitimately means "found problems".
    * `{:error, :unavailable}` -- Prisma is not installed for this project.
    * `{:error, {:exit, code, output}}` -- Prisma crashed or could not analyze.
    * `{:error, {:invalid_json, output}}` -- unexpected output shape.

  ## Examples

      iex> Ragex.Analysis.Prisma.analyze("/path/to/project", mode: :gradual)
      {:ok, [%{kind: "gradual_mismatch", severity: :error, source: :prisma, ...}]}
  """
  @spec analyze(String.t(), keyword()) :: {:ok, [finding()]} | {:error, term()}
  def analyze(project_root \\ ".", opts \\ []) do
    if available?(project_root) do
      format = Keyword.get(opts, :format, :json)

      {output, exit_code} = run(project_root, opts)

      # 0 = clean, 1 = findings present (both are successful analyses)
      if exit_code in [0, 1] do
        parse(output, format)
      else
        {:error, {:exit, exit_code, output}}
      end
    else
      {:error, :unavailable}
    end
  end

  @doc """
  Runs `mix prisma.build` to produce the `.pplt` files Prisma needs.

  Must be run once per project (and again after dependency changes) before
  `analyze/2` can succeed.
  """
  @spec build(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build(project_root \\ ".", opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case System.cmd("mix", ["prisma.build"],
           cd: project_root,
           stderr_to_stdout: true,
           env: env(opts)
         ) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        _ = timeout
        {:error, {:exit, code, output}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Converts normalized Prisma findings into Ragex's dead-code suggestion shape.

  Only oxbow/dead-code findings are convertible; type discrepancies have no
  counterpart in Ragex's model and are returned as `:unsupported`.
  """
  @spec to_dead_code_suggestions([finding()]) :: [map()]
  def to_dead_code_suggestions(findings) do
    findings
    |> Enum.filter(&(&1.kind in ["oxbow_code", "dead_code"]))
    |> Enum.map(fn finding ->
      %{
        type: :review_function,
        confidence: 0.95,
        target: %{
          type: :function,
          module: finding.module,
          name: finding.function,
          arity: finding.arity
        },
        description: finding.message,
        metadata: %{
          source: :prisma,
          kind: finding.kind,
          file: finding.file,
          line: finding.line
        }
      }
    end)
  end

  # --- Private ---

  defp run(project_root, opts) do
    args = ["prisma" | cli_args(opts)]
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task =
      Task.async(fn ->
        System.cmd("mix", args, cd: project_root, stderr_to_stdout: true, env: env(opts))
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, code}} -> {output, code}
      nil -> {"Prisma timed out after #{timeout}ms", 124}
    end
  rescue
    e -> {"Prisma invocation failed: #{Exception.message(e)}", 127}
  end

  defp cli_args(opts) do
    mode = Keyword.get(opts, :mode, :hybrid)
    format = Keyword.get(opts, :format, :json)

    base = ["--mode", to_string(mode), "--format", to_string(format), "--no-color"]

    base
    |> maybe_flag(Keyword.get(opts, :oxbow, true) == false, "--no-oxbow")
    |> maybe_flag(Keyword.get(opts, :warnings_as_errors, false), "--warnings-as-errors")
  end

  defp maybe_flag(args, true, flag), do: args ++ [flag]
  defp maybe_flag(args, false, _flag), do: args

  defp env(opts) do
    # Prisma respects NO_COLOR; set it unconditionally so ANSI escapes can never
    # leak into JSON payloads.
    base = [{"NO_COLOR", "1"}]
    base ++ Keyword.get(opts, :env, [])
  end

  defp parse(output, :json) do
    # Prisma writes a JSON array. Compilation noise from `mix` may precede it,
    # so extract from the first `[` to the last `]`.
    case extract_json(output) do
      nil ->
        # An empty array is emitted as "[]" -- anything else with no array means
        # the run produced no parseable result.
        if String.trim(output) == "", do: {:ok, []}, else: {:error, {:invalid_json, output}}

      json ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) -> {:ok, Enum.map(list, &normalize/1)}
          {:ok, other} -> {:error, {:invalid_json, other}}
          {:error, _} -> {:error, {:invalid_json, json}}
        end
    end
  end

  defp parse(output, _other_format), do: {:ok, parse_lines(output)}

  defp extract_json(output) do
    with start when is_integer(start) <- :binary.match(output, "[") |> match_index(),
         stop when is_integer(stop) <- :binary.matches(output, "]") |> last_index() do
      binary_part(output, start, stop - start + 1)
    else
      _ -> nil
    end
  end

  defp match_index({idx, _len}), do: idx
  defp match_index(:nomatch), do: nil

  defp last_index([]), do: nil
  defp last_index(matches), do: matches |> List.last() |> elem(0)

  defp normalize(map) when is_map(map) do
    %{
      kind: map["kind"],
      severity: severity(map["severity"]),
      module: map["module"],
      function: map["function"],
      arity: map["arity"],
      line: map["line"],
      file: map["file"],
      message: map["message"] || "",
      declared: map["declared"],
      actual: map["actual"],
      expected: map["expected"],
      source: :prisma
    }
  end

  defp normalize(_other), do: nil

  defp severity("error"), do: :error
  defp severity("warning"), do: :warning
  defp severity("note"), do: :note
  defp severity(_), do: :warning

  # Best-effort parsing for the non-JSON formats, which look like
  # `Module:Line: [kind] MFA: message`.
  defp parse_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^(.+?):(\d+):\s*\[(\w+)\]\s*(.*)$/, line) do
        [_, file, line_no, kind, message] ->
          [
            %{
              kind: kind,
              severity: :warning,
              module: nil,
              function: nil,
              arity: nil,
              line: String.to_integer(line_no),
              file: file,
              message: message,
              declared: nil,
              actual: nil,
              expected: nil,
              source: :prisma
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp prisma_dep?(project_root) do
    lock = Path.join(project_root, "mix.lock")

    File.exists?(lock) and
      File.read!(lock) |> String.contains?("\"prisma\"")
  rescue
    _ -> false
  end
end
