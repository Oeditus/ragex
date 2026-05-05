defmodule Ragex.Analyzers.MetaASTExtractor do
  @moduledoc """
  Language-agnostic entity extraction from Metastatic MetaAST.

  Walks a `Metastatic.Document`'s AST to extract modules, functions,
  calls, and imports into the `Ragex.Analyzers.Behaviour.analysis_result()`
  shape. This replaces the native language-specific analyzers for entity
  extraction, providing a single code path that works identically for
  every language Metastatic supports.

  ## Extracted Entities

  - **Modules** -- `:container` nodes with `container_type: :module` or `:class`
  - **Functions** -- `:function_def` nodes with name, arity, visibility
  - **Calls** -- `:function_call` nodes with caller/callee resolution
  - **Imports** -- `:import` nodes with source and import type

  ## Usage

      alias Ragex.Analyzers.MetaASTExtractor
      alias Metastatic.Document

      {:ok, doc} = Ragex.LanguageSupport.parse_file("lib/my_module.ex")
      {:ok, result} = MetaASTExtractor.extract(doc, "lib/my_module.ex")

      result.modules   # => [%{name: "MyModule", file: "lib/my_module.ex", line: 1, ...}]
      result.functions  # => [%{name: :my_func, arity: 2, module: "MyModule", ...}]
      result.calls      # => [%{from_module: "MyModule", to_function: :other, ...}]
      result.imports    # => [%{from_module: "MyModule", to_module: "OtherModule", ...}]
  """

  alias Metastatic.Document

  @type context :: %{
          file: String.t(),
          language: atom(),
          container: term(),
          function: atom() | nil,
          arity: non_neg_integer() | nil
        }

  @type acc :: %{
          modules: [map()],
          functions: [map()],
          calls: [map()],
          imports: [map()]
        }

  @doc """
  Extracts entities from a `Metastatic.Document`.

  Returns `{:ok, analysis_result}` with modules, functions, calls, and imports
  in the shape expected by `Ragex.Analyzers.Behaviour`.

  ## Parameters

  - `doc` -- a `Metastatic.Document` (from `Ragex.LanguageSupport.parse_file/2`)
  - `file_path` -- path to the source file (used in entity metadata)

  ## Examples

      {:ok, doc} = Ragex.LanguageSupport.parse_file("lib/my_module.ex")
      {:ok, result} = MetaASTExtractor.extract(doc, "lib/my_module.ex")
  """
  @spec extract(Document.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def extract(%Document{ast: ast, language: language}, file_path) when is_binary(file_path) do
    ctx = %{
      file: file_path,
      language: language || :unknown,
      container: nil,
      function: nil,
      arity: nil
    }

    acc = %{modules: [], functions: [], calls: [], imports: []}

    {_ast, result} = walk(ast, ctx, acc)

    {:ok,
     %{
       modules: Enum.reverse(result.modules),
       functions: Enum.reverse(result.functions),
       calls: Enum.reverse(result.calls),
       imports: Enum.reverse(result.imports)
     }}
  rescue
    e -> {:error, {:extraction_failed, Exception.message(e)}}
  end

  @doc """
  Convenience wrapper: parses a file and extracts entities in one step.

  ## Examples

      {:ok, result} = MetaASTExtractor.extract_file("lib/my_module.ex")
  """
  @spec extract_file(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def extract_file(path, opts \\ []) do
    with {:ok, doc} <- Ragex.LanguageSupport.parse_file(path, opts) do
      extract(doc, path)
    end
  end

  # Private functions

  # Walk the AST recursively, collecting entities.
  # We do manual recursion instead of AST.traverse/4 because we need
  # to update the context (current container / function) on the way down
  # and restore it on the way up.

  defp walk({:container, meta, body}, ctx, acc) when is_list(meta) and is_list(body) do
    raw_name = Keyword.get(meta, :name, "unknown")
    name = normalize_module_name(raw_name, ctx.language)
    line = Keyword.get(meta, :line, 0)
    container_type = Keyword.get(meta, :container_type, :module)

    mod_entry = %{
      name: name,
      file: ctx.file,
      line: line,
      doc: nil,
      metadata: %{container_type: container_type}
    }

    acc = %{acc | modules: [mod_entry | acc.modules]}
    inner_ctx = %{ctx | container: name}

    # Walk children with updated context
    {body, acc} = walk_list(body, inner_ctx, acc)
    {{:container, meta, body}, acc}
  end

  defp walk({:function_def, meta, body}, ctx, acc) when is_list(meta) and is_list(body) do
    name_str = Keyword.get(meta, :name, "unknown")
    params = Keyword.get(meta, :params, [])
    visibility = Keyword.get(meta, :visibility, :public)
    line = Keyword.get(meta, :line, 0)
    arity = length(params)

    func_entry = %{
      name: String.to_atom(name_str),
      arity: arity,
      module: ctx.container || "top_level",
      file: ctx.file,
      line: line,
      doc: nil,
      visibility: visibility,
      metadata: %{params: extract_param_names(params)}
    }

    acc = %{acc | functions: [func_entry | acc.functions]}

    inner_ctx = %{
      ctx
      | function: String.to_atom(name_str),
        arity: arity
    }

    # Walk body with function context
    {body, acc} = walk_list(body, inner_ctx, acc)
    {{:function_def, meta, body}, acc}
  end

  defp walk({:function_call, meta, args}, ctx, acc) when is_list(meta) and is_list(args) do
    name_str = Keyword.get(meta, :name, "unknown")
    line = Keyword.get(meta, :line, 0)
    call_arity = length(args)

    {to_module, to_function} = split_call_name(name_str, ctx.language)

    call_entry = %{
      from_module: ctx.container || normalize_module_name("top_level", ctx.language),
      from_function: ctx.function || :top_level,
      from_arity: ctx.arity || 0,
      to_module: to_module,
      to_function: to_function,
      to_arity: call_arity,
      line: line
    }

    acc = %{acc | calls: [call_entry | acc.calls]}

    # Walk arguments for nested calls
    {args, acc} = walk_list(args, ctx, acc)
    {{:function_call, meta, args}, acc}
  end

  defp walk({:import, meta, children}, ctx, acc) when is_list(meta) do
    source = Keyword.get(meta, :source, "unknown")
    import_type = Keyword.get(meta, :import_type, :import)

    import_entry = %{
      from_module: ctx.container || normalize_module_name("top_level", ctx.language),
      to_module: normalize_module_name(source, ctx.language),
      type: import_type
    }

    acc = %{acc | imports: [import_entry | acc.imports]}
    {{:import, meta, children}, acc}
  end

  # Child spec nodes: extract supervisor child metadata
  defp walk({:child_spec, meta, body}, ctx, acc) when is_list(meta) do
    mod = Keyword.get(meta, :module, "unknown")
    id = Keyword.get(meta, :id, "unknown")
    kind = Keyword.get(meta, :kind, :worker)
    line = Keyword.get(meta, :line, 0)

    call_entry = %{
      from_module: ctx.container || "top_level",
      from_function: :child_spec,
      from_arity: 0,
      to_module: mod,
      to_function: :start_link,
      to_arity: 1,
      line: line,
      metadata: %{child_id: id, child_kind: kind}
    }

    acc = %{acc | calls: [call_entry | acc.calls]}
    {{:child_spec, meta, body}, acc}
  end

  # Generic 3-tuple node: recurse into list children
  defp walk({type, meta, children}, ctx, acc)
       when is_atom(type) and is_list(meta) and is_list(children) do
    {children, acc} = walk_list(children, ctx, acc)
    {{type, meta, children}, acc}
  end

  # 3-tuple with non-list children (leaf-like): pass through
  defp walk({type, meta, value}, _ctx, acc) when is_atom(type) and is_list(meta) do
    {{type, meta, value}, acc}
  end

  # Bare list (top-level or nested statements)
  defp walk(list, ctx, acc) when is_list(list) do
    walk_list(list, ctx, acc)
  end

  # Anything else (literals, nil, etc.)
  defp walk(other, _ctx, acc), do: {other, acc}

  defp walk_list(list, ctx, acc) do
    Enum.map_reduce(list, acc, fn node, acc -> walk(node, ctx, acc) end)
  end

  # Split "Module.func" into {module, :func}.
  # Handles dotted names like "Enum.map", "MyApp.Repo.get", and bare "func".
  # Module part is normalized according to language conventions.
  defp split_call_name(name, language) when is_binary(name) do
    case String.split(name, ".") do
      [single] ->
        {nil, String.to_atom(single)}

      parts ->
        func = List.last(parts)
        mod = parts |> Enum.drop(-1) |> Enum.join(".")
        {normalize_module_name(mod, language), String.to_atom(func)}
    end
  end

  # Normalize module names according to language conventions.
  # Elixir: "TestModule" -> Module atom (Elixir.TestModule)
  # Erlang: "my_module" -> :my_module atom
  # Others: kept as strings
  defp normalize_module_name(name, :elixir) when is_binary(name) do
    name
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
    |> Module.concat()
  end

  defp normalize_module_name(name, :erlang) when is_binary(name) do
    String.to_atom(name)
  end

  defp normalize_module_name(name, _language), do: name

  defp extract_param_names(params) do
    Enum.map(params, fn
      {:param, _meta, name} when is_binary(name) -> name
      _ -> "_"
    end)
  end
end
