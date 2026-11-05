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
  0.3.1) measured:

    * **27.5% of files crash** -- `Typle.Inference.Expr.infer/2` has no clause
      for the struct-update node `%{struct | key: value}`, which parses as
      `{:|, _, [struct, [key: value]]}` and reaches the map-literal clause as a
      bare `:|` tuple. 16.6% of files in this repo use that syntax, so this is
      a hard blocker rather than a nuisance.
    * **87.6% of inferred expressions are `dynamic()`** on the files that do
      succeed (8,464 of 9,661). Typle returns `dynamic()` when it cannot
      infer, so the signal is too thin to justify surfacing as a first-class
      graph property today.

  Both are upstream issues in Typle, not in Ragex. This module therefore
  exists to make the capability *available and safe* -- every entry point is
  guarded and returns `{:error, :unavailable}` / `{:error, reason}` rather than
  raising -- so that enabling it later is a configuration change, not a
  rewrite. Re-run `mix ragex.typle.spike` after a Typle release to see whether
  the numbers moved.

  ## Enabling

      config :ragex, type_inference: :enabled

  or set `RAGEX_TYPE_INFERENCE=1`. Even when enabled, Typle is only used if it
  is actually loaded, so the dependency can stay `optional: true`.
  """

  require Logger

  @type type_map :: %{{non_neg_integer(), non_neg_integer()} => term()}

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

  Returns `{:ok, %{{line, col} => type}}`, or `{:error, :unavailable}` when the
  feature is off, or `{:error, reason}` when Typle fails on this file.

  Typle raises on some real-world syntax (see the moduledoc), so the call is
  wrapped: a crash is reported as an error, never propagated.
  """
  @spec types_for_file(String.t()) :: {:ok, type_map()} | {:error, term()}
  def types_for_file(file) do
    if available?() do
      with {:ok, map} <- guarded(fn -> Typle.types_for_file(file) end) do
        {:ok, unwrap(map)}
      end
    else
      {:error, :unavailable}
    end
  end

  @doc """
  Returns the inferred type at a `{line, column}`, or `nil`.

  Convenience wrapper over `types_for_file/1` for callers that only need one
  position.
  """
  @spec type_at(String.t(), non_neg_integer(), non_neg_integer()) :: term() | nil
  def type_at(file, line, col) do
    case types_for_file(file) do
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
    if available?() do
      guarded(fn -> Typle.return_type(module, function, arity) end)
    else
      {:error, :unavailable}
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

  # Typle returns `{:ok, %{pos => %{type: t, expr: s}}}` by default (`:expr`
  # defaults to true). Callers of this module want the type, not the source
  # string, so unwrap uniformly.
  defp unwrap(map) when is_map(map) do
    Map.new(map, fn
      {pos, %{type: type}} -> {pos, type}
      {pos, type} -> {pos, type}
    end)
  end

  # Typle raises on unsupported syntax (struct updates, for one). Never let
  # that escape into an analyzer run.
  defp guarded(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("TypeInfo: Typle failed: #{Exception.message(e)}")
      {:error, {:typle_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:typle_failed, {kind, reason}}}
  end
end
