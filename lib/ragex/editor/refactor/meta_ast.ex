defmodule Ragex.Editor.Refactor.MetaAST do
  @moduledoc """
  Language-agnostic refactoring operations via Metastatic MetaAST.

  Performs AST-aware rename operations on any language supported by
  Metastatic by traversing and transforming the MetaAST representation,
  then converting back to source code via `Metastatic.Builder.to_source/1`.

  ## Supported Operations

  - `rename_function/4` -- renames a function definition and all call sites
  - `rename_module/3` -- renames a module/class and updates references

  ## Usage

      alias Ragex.Editor.Refactor.MetaAST, as: MetaRefactor

      {:ok, new_source} = MetaRefactor.rename_function(source, :elixir, "old_name", "new_name")
      {:ok, new_source} = MetaRefactor.rename_module(source, :elixir, "OldModule", "NewModule")
  """

  alias Metastatic.{AST, Builder, Document}

  @doc """
  Renames a function definition and all its call sites in source code.

  ## Parameters

  - `source` -- source code string
  - `language` -- language atom
  - `old_name` -- current function name (string)
  - `new_name` -- new function name (string)
  - `opts` -- options
    - `:arity` -- only rename functions with this arity (default: all arities)
    - `:module` -- only rename within this module/container (default: all)

  ## Returns

  - `{:ok, new_source}` on success
  - `{:error, reason}` on failure
  """
  @spec rename_function(String.t(), atom(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def rename_function(source, language, old_name, new_name, opts \\ []) do
    target_arity = Keyword.get(opts, :arity)
    target_module = Keyword.get(opts, :module)

    with {:ok, doc} <- Builder.from_source(source, language) do
      {new_ast, _acc} =
        AST.traverse(
          doc.ast,
          nil,
          fn node, acc ->
            {rename_fn_pre(node, old_name, new_name, target_arity, target_module), acc}
          end,
          fn node, acc -> {node, acc} end
        )

      new_doc = %{doc | ast: new_ast}
      Builder.to_source(new_doc)
    end
  end

  @doc """
  Renames a module/class and updates all references in source code.

  ## Parameters

  - `source` -- source code string
  - `language` -- language atom
  - `old_name` -- current module name (string, e.g. "MyApp.OldModule")
  - `new_name` -- new module name (string, e.g. "MyApp.NewModule")

  ## Returns

  - `{:ok, new_source}` on success
  - `{:error, reason}` on failure
  """
  @spec rename_module(String.t(), atom(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def rename_module(source, language, old_name, new_name) do
    with {:ok, doc} <- Builder.from_source(source, language) do
      {new_ast, _acc} =
        AST.traverse(
          doc.ast,
          nil,
          fn node, acc -> {rename_mod_pre(node, old_name, new_name), acc} end,
          fn node, acc -> {node, acc} end
        )

      new_doc = %{doc | ast: new_ast}
      Builder.to_source(new_doc)
    end
  end

  @doc """
  Same as `rename_function/5` but operates on a `Metastatic.Document` directly.

  Returns `{:ok, new_doc}` with the transformed document.
  """
  @spec rename_function_doc(Document.t(), String.t(), String.t(), keyword()) ::
          {:ok, Document.t()}
  def rename_function_doc(%Document{} = doc, old_name, new_name, opts \\ []) do
    target_arity = Keyword.get(opts, :arity)
    target_module = Keyword.get(opts, :module)

    {new_ast, _acc} =
      AST.traverse(
        doc.ast,
        nil,
        fn node, acc ->
          {rename_fn_pre(node, old_name, new_name, target_arity, target_module), acc}
        end,
        fn node, acc -> {node, acc} end
      )

    {:ok, %{doc | ast: new_ast}}
  end

  @doc """
  Same as `rename_module/4` but operates on a `Metastatic.Document` directly.
  """
  @spec rename_module_doc(Document.t(), String.t(), String.t()) :: {:ok, Document.t()}
  def rename_module_doc(%Document{} = doc, old_name, new_name) do
    {new_ast, _acc} =
      AST.traverse(
        doc.ast,
        nil,
        fn node, acc -> {rename_mod_pre(node, old_name, new_name), acc} end,
        fn node, acc -> {node, acc} end
      )

    {:ok, %{doc | ast: new_ast}}
  end

  # Private functions

  # -- Function rename helpers --

  # Rename function_def nodes
  #
  # `:name` is a display string. When the definition has a receiver
  # (`def self.list`, `def Foo.bar`) it is qualified, so only the trailing
  # segment is the function name and the receiver prefix must be preserved.
  defp rename_fn_pre({:function_def, meta, body}, old_name, new_name, target_arity, target_module) do
    name = Keyword.get(meta, :name)
    params = Keyword.get(meta, :params, [])
    arity = length(params)

    if bare_name(name) == old_name and arity_matches?(arity, target_arity) and
         module_matches?(meta, target_module) do
      {:function_def, Keyword.put(meta, :name, requalify(name, new_name)), body}
    else
      {:function_def, meta, body}
    end
  end

  # Rename function_call nodes (bare calls and qualified calls)
  #
  # `:name` is a display string only -- since Metastatic 0.44 the receiver of a
  # qualified call travels separately in `:receiver`, and `FromMeta` rebuilds
  # the call from that key, never by parsing `:name`. Renaming therefore has to
  # rewrite the trailing segment of `:name` and leave `:receiver` untouched;
  # rewriting the receiver would move the call to a different object.
  defp rename_fn_pre(
         {:function_call, meta, args},
         old_name,
         new_name,
         target_arity,
         _target_module
       ) do
    call_name = Keyword.get(meta, :name, "")
    call_arity = length(args)

    if bare_name(call_name) == old_name and arity_matches?(call_arity, target_arity) do
      {:function_call, Keyword.put(meta, :name, requalify(call_name, new_name)), args}
    else
      {:function_call, meta, args}
    end
  end

  # Pass through everything else
  defp rename_fn_pre(node, _old, _new, _arity, _module), do: node

  # -- Module rename helpers --

  # Rename container (module/class) nodes
  defp rename_mod_pre({:container, meta, body}, old_name, new_name) do
    name = Keyword.get(meta, :name)

    if name == old_name do
      {:container, Keyword.put(meta, :name, new_name), body}
    else
      {:container, meta, body}
    end
  end

  # Rename import source references
  defp rename_mod_pre({:import, meta, children}, old_name, new_name) do
    source = Keyword.get(meta, :source, "")

    if source == old_name do
      {:import, Keyword.put(meta, :source, new_name), children}
    else
      {:import, meta, children}
    end
  end

  # Rename qualified function calls whose receiver names the old module.
  #
  # The receiver travels in `:receiver` (a MetaAST node) since Metastatic
  # 0.44, and `:name` is only its display rendering. Both are rewritten so
  # that a reified call and its display string agree; missing `:receiver`
  # (older MetaAST, or a bare call) leaves the node's receiver untouched.
  defp rename_mod_pre({:function_call, meta, args}, old_name, new_name) do
    call_name = Keyword.get(meta, :name, "")

    meta =
      case Keyword.get(meta, :receiver) do
        {:literal, recv_meta, ^old_name} ->
          Keyword.put(meta, :receiver, {:literal, recv_meta, new_name})

        _ ->
          meta
      end

    if String.starts_with?(call_name, old_name <> ".") do
      suffix = String.slice(call_name, String.length(old_name)..-1//1)
      {:function_call, Keyword.put(meta, :name, new_name <> suffix), args}
    else
      {:function_call, meta, args}
    end
  end

  # Pass through everything else
  defp rename_mod_pre(node, _old, _new), do: node

  # -- Helpers --

  # The trailing segment of a possibly-qualified display name.
  defp bare_name(name) when is_binary(name), do: name |> String.split(".") |> List.last()
  defp bare_name(name), do: name

  # Replaces the trailing segment of a display name, keeping any qualifier.
  defp requalify(name, new_name) when is_binary(name) do
    case String.split(name, ".") do
      [_bare] -> new_name
      parts -> parts |> Enum.drop(-1) |> Kernel.++([new_name]) |> Enum.join(".")
    end
  end

  defp requalify(_name, new_name), do: new_name

  defp arity_matches?(_actual, nil), do: true
  defp arity_matches?(actual, target), do: actual == target

  defp module_matches?(_meta, nil), do: true

  defp module_matches?(meta, target_module) do
    Keyword.get(meta, :module) == target_module or
      Keyword.get(meta, :container) == target_module
  end
end
