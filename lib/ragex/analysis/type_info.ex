defmodule Ragex.Analysis.TypeInfo do
  @moduledoc """
  Optional bridge to [Typle](https://typle.hexdocs.pm) for expression-level type
  inference.

  Typle reads the types the Elixir 1.20 compiler infers back out of `.beam`
  `ExCk` chunks and re-derives per-expression types from source, answering
  *"what type did the compiler infer for this expression?"* -- something no
  other Elixir tooling exposes.

  ## Status: opt-in, not enabled by default

  A spike against this repository (40 files, Elixir 1.20.4 / OTP 29, Typle
  0.4.0) measured:

  | classification | share |
  |---|---|
  | `dynamic()` -- no inference | 82.5% |
  | empty type (`Type<>`) | 3.2% |
  | `map()` only (map/struct literals) | 5.9% |
  | **genuinely informative** | **~5%** |

  Typle returns `dynamic()` when it cannot infer, and `map()` for any map or
  struct literal -- neither says anything about the values flowing through the
  program. What remains is ~5% of expressions, which is too thin to justify
  surfacing types as a first-class graph property: a feature built on it would
  look confident and be wrong most of the time.

  Two crashes had to be fixed before even this number could be measured, both
  released in Typle 0.4.0: struct updates (`%{struct | key: value}`), and
  `with`/`for` body splicing inherited from ExPanda 0.2.x. With both fixed the
  crash rate on this repository is 0%, so these figures are a fair measurement
  of the signal rather than of the files that happened to survive.

  This module therefore exists to make the capability *available and safe* --
  every entry point is guarded and returns `{:error, :unavailable}` /
  `{:error, reason}` rather than raising -- so that enabling it later is a
  configuration change, not a rewrite. Re-run `mix ragex.typle.spike` after a
  Typle release to see whether the numbers moved.

  ## Enabling

      config :ragex, type_inference: :enabled

  or set `RAGEX_TYPE_INFERENCE=1`. Even when enabled, Typle is only used if it
  is actually loaded, so the dependency can stay `optional: true`.
  """

  require Logger

  @type type_info :: %{
          type: term(),
          expr: String.t() | nil,
          informative?: boolean()
        }
  @type type_map :: %{{non_neg_integer(), non_neg_integer()} => type_info()}

  @doc """
  Returns whether type inference is both configured and actually usable.

  Requires the `:typle` application to be loadable *and* the feature to be
  switched on; a missing dependency is never an error.
  """
  @spec available?() :: boolean()
  def available? do
    enabled?() and Code.ensure_loaded?(Typle)
  end

  @doc """
  Returns whether the feature is switched on, regardless of whether Typle is
  present.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:ragex, :type_inference, :disabled) do
      true -> true
      :enabled -> true
      _ -> System.get_env("RAGEX_TYPE_INFERENCE") in ["1", "true"]
    end
  end

  @doc """
  Infers types for every expression in `file`.

  Returns `{:ok, %{{line, col} => type_info}}`, or `{:error, :unavailable}`
  when the feature is off, or `{:error, reason}` when Typle fails on this file.

  Typle raises on some real-world syntax, so the call is wrapped: a crash is
  reported as an error, never propagated.

  ## Options

    * `:unstable` -- use Typle's compiler-replay engine for deeper inference.
      Defaults to `false`; that engine depends on private compiler APIs.
  """
  @spec types_for_file(String.t(), keyword()) :: {:ok, type_map()} | {:error, term()}
  def types_for_file(file, opts \\ []) do
    case guarded(available?(), fn -> Typle.types_for_file(file, typle_opts(opts)) end) do
      {:ok, map} when is_map(map) ->
        {:ok, Map.new(map, fn {pos, value} -> {pos, normalize(value)} end)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the inferred type at `{line, column}`, or `nil`.

  Convenience wrapper over `types_for_file/2` for callers that only need one
  position.
  """
  @spec type_at(String.t(), non_neg_integer(), non_neg_integer(), keyword()) :: type_info() | nil
  def type_at(file, line, col, opts \\ []) do
    case types_for_file(file, opts) do
      {:ok, map} -> Map.get(map, {line, col})
      {:error, _} -> nil
    end
  end

  @doc """
  Returns the inferred return type of `module.function/arity`.

  Reads the compiled `.beam` signature table, so the module must be compiled.
  """
  @spec return_type(module(), atom(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def return_type(module, function, arity) do
    guarded(available?(), fn -> Typle.return_type(module, function, arity) end)
  end

  @doc """
  Summarises how informative the inferred types for `file` are.

  Returns counts and the share of genuinely informative types, matching the
  classification in the moduledoc. Useful for deciding whether type data is
  worth acting on for a given file.
  """
  @spec summarize(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def summarize(file, opts \\ []) do
    case types_for_file(file, opts) do
      {:ok, map} ->
        total = map_size(map)
        informative = Enum.count(map, fn {_pos, info} -> info.informative? end)
        dynamic = Enum.count(map, fn {_pos, info} -> dynamic?(info.type) end)

        {:ok,
         %{
           total: total,
           dynamic: dynamic,
           informative: informative,
           informative_ratio: ratio(informative, total),
           dynamic_ratio: ratio(dynamic, total)
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns whether an inferred type is `dynamic()` -- i.e. Typle could not
  determine anything useful.

  Used by the spike task to report signal quality, and by callers that want to
  skip attaching a type that carries no information.
  """
  @spec dynamic?(term()) :: boolean()
  def dynamic?(nil), do: false

  def dynamic?(%{dynamic?: true}), do: true
  def dynamic?(%{dynamic?: false}), do: false

  # `Typle.Type` is a plain struct with a `kind` field; `dynamic()` is its own
  # kind, so check it directly rather than relying on `inspect/1` (which
  # renders a bare map when the struct module is not loaded).
  def dynamic?(%{kind: :dynamic}), do: true

  def dynamic?(type) do
    inspect(type) |> String.contains?("dynamic(")
  end

  @doc """
  Classifies a single inferred type as informative or not.

  A type is informative when it is neither `dynamic()` (Typle could not infer
  anything) nor the empty type `Type<>` (a position with no type), and is not
  merely `map()` -- map and struct literals are trivially typed and say nothing
  about the values flowing through the program.

  Exposed so callers can apply the same judgement to types obtained elsewhere.
  """
  @spec informative?(term()) :: boolean()
  def informative?(type) do
    rendered = render(type)

    rendered != "" and
      not String.contains?(rendered, "dynamic(") and
      rendered != "map()"
  end

  # --- Private ---

  defp typle_opts(opts), do: Keyword.take(opts, [:unstable, :expr])

  defp normalize(%{type: type} = result), do: to_info(type, Map.get(result, :expr))
  defp normalize(type), do: to_info(type, nil)

  defp to_info(type, expr) do
    %{type: type, expr: expr, informative?: informative?(type)}
  end

  defp render(type) do
    cond do
      is_nil(type) -> ""
      is_binary(type) -> type
      # credo:disable-for-next-line
      function_exported?(Typle.Type, :to_string, 1) -> apply(Typle.Type, :to_string, [type])
      true -> inspect(type)
    end
  end

  defp ratio(_part, 0), do: 0.0
  defp ratio(part, total), do: Float.round(part / total, 4)

  # Typle raises on unsupported syntax (struct updates, for one). Never let
  # that escape into an analyzer run.
  defp guarded(false = _available?, _fun), do: {:error, :unavailable}

  defp guarded(_, fun) do
    fun.()
  rescue
    e ->
      Logger.debug("TypeInfo: Typle failed: #{Exception.message(e)}")
      {:error, {:typle_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:typle_failed, {kind, reason}}}
  end
end
