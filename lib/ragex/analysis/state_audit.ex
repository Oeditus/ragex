defmodule Ragex.Analysis.StateAudit do
  @moduledoc """
  Audits Elixir modules for GenServer state management anti-patterns and potential deadlocks.

  Detects:
  - **Unstructured State**: Initializing GenServer state as a raw map `%{}` instead of a struct `%State{}`.
  - **Sync Calls in Callback**: Invoking `GenServer.call/3` inside callback handlers (`handle_call`, `handle_cast`, `handle_info`).
  """

  @type audit_issue :: %{
          type: :unstructured_state | :sync_call_in_callback,
          severity: :warning | :info,
          description: String.t(),
          suggestion: String.t(),
          line: non_neg_integer()
        }

  @type audit_result :: %{
          file: String.t(),
          is_genserver?: boolean(),
          issues: [audit_issue()],
          has_issues?: boolean()
        }

  @doc """
  Audits a file's AST for GenServer anti-patterns.
  """
  @spec audit_file(String.t()) :: {:ok, audit_result()} | {:error, term()}
  def audit_file(path) do
    case File.read(path) do
      {:ok, source} ->
        case Code.string_to_quoted(source) do
          {:ok, quoted} ->
            issues = run_audit(quoted)
            is_genserver = is_genserver?(quoted)

            {:ok,
             %{
               file: path,
               is_genserver?: is_genserver,
               issues: issues,
               has_issues?: not Enum.empty?(issues)
             }}

          {:error, reason} ->
            {:error, {:parse_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  @doc """
  Audits all files in a directory recursively.
  """
  @spec audit_directory(String.t()) :: {:ok, [audit_result()]} | {:error, term()}
  def audit_directory(dir_path) do
    files = find_elixir_files(dir_path)

    results =
      files
      |> Enum.map(fn file ->
        case audit_file(file) do
          {:ok, res} -> res
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, results}
  end

  # AST Traversal and Audit Logic

  defp is_genserver?(quoted) do
    ref = :erlang.make_ref()

    try do
      Macro.prewalk(quoted, fn
        {:use, _, [{:__aliases__, _, [:GenServer]} | _]} ->
          throw({ref, true})

        other ->
          other
      end)

      false
    catch
      {^ref, true} -> true
    end
  end

  defp run_audit(quoted) do
    issues = []

    # 1. Audit init/1 for raw map state
    issues = issues ++ audit_init_state(quoted)

    # 2. Audit handle_* callbacks for GenServer.call
    issues = issues ++ audit_callback_sync_calls(quoted)

    issues
  end

  defp audit_init_state(quoted) do
    {_, collected} =
      Macro.prewalk(quoted, [], fn
        {:def, meta, [{:init, _, _args}, [do: body]]} = node, acc ->
          returns = find_returns(body)

          node_issues =
            returns
            |> Enum.map(fn {state_val, line} ->
              if is_raw_map?(state_val) do
                %{
                  type: :unstructured_state,
                  severity: :warning,
                  description: "GenServer state initialized as a raw map instead of a struct",
                  suggestion:
                    "Define a struct (e.g. %State{}) to represent the GenServer's state for safety and type specs.",
                  line: line || Keyword.get(meta, :line, 1)
                }
              else
                nil
              end
            end)
            |> Enum.reject(&is_nil/1)

          {node, acc ++ node_issues}

        other, acc ->
          {other, acc}
      end)

    collected
  end

  defp is_raw_map?({:%{}, _, []}), do: true

  defp is_raw_map?({:%{}, _, _fields}) do
    # Check if it is a raw map and not a struct
    true
  end

  defp is_raw_map?(_), do: false

  defp find_returns(body) do
    case body do
      {:__block__, _, exprs} ->
        # Check last expression and conditional branches
        Enum.flat_map(exprs, &find_returns_in_expr/1)

      expr ->
        find_returns_in_expr(expr)
    end
  end

  defp find_returns_in_expr(expr) do
    case expr do
      {:ok, state_val} ->
        [{state_val, get_line(state_val)}]

      {:{}, meta, [:ok, state_val]} ->
        [{state_val, Keyword.get(meta, :line)}]

      {:{}, meta, [:ok, state_val, _]} ->
        [{state_val, Keyword.get(meta, :line)}]

      {:if, _, [_cond, [do: do_branch, else: else_branch]]} ->
        find_returns(do_branch) ++ find_returns(else_branch)

      _ ->
        []
    end
  end

  defp get_line({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line)
  defp get_line(_), do: nil

  defp audit_callback_sync_calls(quoted) do
    {_, collected} =
      Macro.prewalk(quoted, [], fn
        {:def, meta, [{name, _, _args}, [do: body]]} = node, acc
        when name in [:handle_call, :handle_cast, :handle_info] ->
          calls = find_sync_calls(body)

          node_issues =
            Enum.map(calls, fn line ->
              %{
                type: :sync_call_in_callback,
                severity: :warning,
                description: "Synchronous GenServer.call invoked inside callback #{name}",
                suggestion:
                  "Avoid synchronous calls inside callback handlers. They can lead to performance bottlenecks or deadlocks. Use GenServer.cast or handle asynchronous communication.",
                line: line || Keyword.get(meta, :line, 1)
              }
            end)

          {node, acc ++ node_issues}

        other, acc ->
          {other, acc}
      end)

    collected
  end

  defp find_sync_calls(body) do
    {_, collected} =
      Macro.prewalk(body, [], fn
        {{:., meta, [{:__aliases__, _, [:GenServer]}, :call]}, _, _args} = node, acc ->
          line = Keyword.get(meta, :line)
          {node, [line | acc]}

        other, acc ->
          {other, acc}
      end)

    collected
  end

  defp find_elixir_files(dir_path) do
    case File.ls(dir_path) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir_path, entry)

          cond do
            File.dir?(full) -> find_elixir_files(full)
            String.ends_with?(full, [".ex", ".exs"]) -> [full]
            true -> []
          end
        end)

      _ ->
        []
    end
  end
end
