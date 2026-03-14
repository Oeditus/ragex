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
  defp rename_fn_pre({:function_def, meta, body}, old_name, new_name, target_arity, target_module) do
    name = Keyword.get(meta, :name)
    params = Keyword.get(meta, :params, [])
    arity = length(params)

    if name == old_name and arity_matches?(arity, target_arity) and
         module_matches?(meta, target_module) do
      {:function_def, Keyword.put(meta, :name, new_name), body}
    else
      {:function_def, meta, body}
    end
  end

  # Rename function_call nodes (bare calls and qualified calls)
  defp rename_fn_pre(
         {:function_call, meta, args},
         old_name,
         new_name,
         target_arity,
         _target_module
       ) do
    call_name = Keyword.get(meta, :name, "")
    call_arity = length(args)

    cond do
      # Bare call: "old_name" -> "new_name"
      call_name == old_name and arity_matches?(call_arity, target_arity) ->
        {:function_call, Keyword.put(meta, :name, new_name), args}

      # Qualified call: "Module.old_name" -> "Module.new_name"
      String.ends_with?(call_name, "." <> old_name) and arity_matches?(call_arity, target_arity) ->
        prefix = String.slice(call_name, 0, String.length(call_name) - String.length(old_name))
        {:function_call, Keyword.put(meta, :name, prefix <> new_name), args}

      true ->
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

  # Rename qualified function calls whose prefix matches the old module
  defp rename_mod_pre({:function_call, meta, args}, old_name, new_name) do
    call_name = Keyword.get(meta, :name, "")

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

  defp arity_matches?(_actual, nil), do: true
  defp arity_matches?(actual, target), do: actual == target

  defp module_matches?(_meta, nil), do: true

  defp module_matches?(meta, target_module) do
    Keyword.get(meta, :module) == target_module or
      Keyword.get(meta, :container) == target_module
  end
end
