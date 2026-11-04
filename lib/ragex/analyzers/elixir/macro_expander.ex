defmodule Ragex.Analyzers.Elixir.MacroExpander do
  @moduledoc """
  Macro expansion for the Elixir analyzer, backed by `ExPanda`.

  `Code.string_to_quoted/2` yields the *surface* AST: `|>`, `unless`, `use GenServer`
  and library DSLs all remain opaque calls. That is insufficient for a call-graph
  analyzer, because it hides both real control flow and the definitions a `use`
  directive injects.

  This module produces a *semantically expanded* AST while keeping `defmodule` and
  `def`/`defp` structure intact, so the analyzer's traversal still sees the module
  and function boundaries it relies on.

  ## Expansion modes

    * `:none` — surface AST, untouched. Fastest; no macro resolution at all.
    * `:partial` — expand with a fresh `Macro.Env`. Resolves core Elixir macros
      (`|>`, `unless`, `if`, ...) and `use` for modules already loaded in the
      analyzing runtime (e.g. `GenServer`). This is the default.
    * `:full` — expand with the caller's `Macro.Env`, so project-local macros and
      loaded dependencies resolve too.

  ## Unexpandable macros

  `ExPanda` never crashes on a macro it cannot resolve. Instead it preserves the
  original node and prepends an `@unexpanded` marker attribute:

      {:__block__, [], [
        {:@, [], [{:unexpanded, [], ["use/1: use: module Ecto.Schema is not available"]}]},
        {:use, [], [{:__aliases__, [], [:Ecto, :Schema]}]}
      ]}

  `strip_markers/1` removes those markers before traversal, and
  `unexpanded/1` reports them so callers can surface a confidence signal rather
  than silently degrading.
  """

  @type mode :: :none | :partial | :full

  @doc """
  Expands `ast` according to `mode`.

  Returns the expanded AST. On any expansion failure the original AST is
  returned unchanged, so the analyzer always makes progress.

  ## Options

    * `:env` — a `Macro.Env` to expand with. Defaults to a fresh environment
      (`:elixir_env.new/0`) for `:partial`, and to the caller's `__ENV__` for
      `:full`.
    * `:file` — file path recorded in the expansion environment.

  ## Examples

      iex> {:ok, ast} = Code.string_to_quoted("data |> Repo.insert()")
      iex> expanded = Ragex.Analyzers.Elixir.MacroExpander.expand(ast, :partial)
      iex> match?({{:., _, [Repo, :insert]}, _, [_]}, expanded)
      true
  """
  @spec expand(Macro.t(), mode(), keyword()) :: Macro.t()
  def expand(ast, mode, opts \\ [])

  def expand(ast, :none, _opts), do: ast

  def expand(ast, mode, opts) when mode in [:partial, :full] do
    env = Keyword.get(opts, :env) || default_env(mode)
    file = Keyword.get(opts, :file)

    env = if file, do: %{env | file: file}, else: env

    case ExPanda.expand(ast, env, []) do
      {:ok, expanded, _final_env} -> expanded
      # ExPanda catches internally and returns {:error, reason}; be defensive
      # anyway so a future ExPanda change cannot take the analyzer down.
      {:error, _reason} -> ast
    end
  rescue
    _ -> ast
  end

  @doc """
  Returns the list of human-readable reasons a macro could not be expanded.

  Empty when the whole AST expanded cleanly. Non-empty means the resulting
  analysis is partial and callers may want to lower their confidence.

  ## Examples

      iex> {:ok, ast} = Code.string_to_quoted("defmodule S do\\n  use NoSuchModule\\nend")
      iex> expanded = Ragex.Analyzers.Elixir.MacroExpander.expand(ast, :partial)
      iex> Ragex.Analyzers.Elixir.MacroExpander.unexpanded(expanded)
      ["use/1: use: module NoSuchModule is not available"]
  """
  @spec unexpanded(Macro.t()) :: [String.t()]
  def unexpanded(ast) do
    {_ast, reasons} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:unexpanded, _, [reason]}]} = node, acc when is_binary(reason) ->
          {node, [reason | acc]}

        node, acc ->
          {node, acc}
      end)

    reasons |> Enum.reverse() |> Enum.uniq()
  end

  @doc """
  Removes `@unexpanded` marker attributes from the AST.

  The markers exist purely as diagnostics; leaving them in place would make the
  analyzer record phantom attributes and, worse, attribute them to whatever
  function encloses them.

  ## Examples

      iex> {:ok, ast} = Code.string_to_quoted("defmodule S do\\n  use NoSuchModule\\nend")
      iex> expanded = Ragex.Analyzers.Elixir.MacroExpander.expand(ast, :partial)
      iex> Ragex.Analyzers.Elixir.MacroExpander.strip_markers(expanded)
      ...> |> Macro.to_string() |> String.contains?("@unexpanded")
      false
  """
  @spec strip_markers(Macro.t()) :: Macro.t()
  def strip_markers(ast) do
    Macro.prewalk(ast, fn
      {:@, _, [{:unexpanded, _, [_reason]}]} -> nil
      node -> node
    end)
  end

  @doc """
  Returns the modules referenced by `use` directives in the *unexpanded* AST.

  ExPanda rewrites `use GenServer` into `require GenServer` plus the injected
  body, so after expansion the `:use` relationship is no longer visible. The
  analyzer still wants that edge ("which modules does this one build on?"), so
  we recover it from the surface AST before expanding.

  ## Examples

      iex> {:ok, ast} = Code.string_to_quoted("defmodule S do\\n  use GenServer\\nend")
      iex> Ragex.Analyzers.Elixir.MacroExpander.use_targets(ast)
      [GenServer]
  """
  @spec use_targets(Macro.t()) :: [module()]
  def use_targets(ast) do
    {_ast, targets} =
      Macro.prewalk(ast, [], fn
        {:use, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, [Module.concat(parts) | acc]}

        {:use, _, [mod | _]} = node, acc when is_atom(mod) ->
          {node, [mod | acc]}

        node, acc ->
          {node, acc}
      end)

    targets |> Enum.reverse() |> Enum.uniq()
  end

  # A fresh compilation environment (Kernel preloaded) is the right base for
  # `:partial`: it resolves core macros without pretending to know the
  # project's own macro table.
  defp default_env(:partial), do: ExPanda.EnvManager.new_env()
  defp default_env(:full), do: __ENV__
end
