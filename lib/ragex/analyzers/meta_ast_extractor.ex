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

  ## Qualified calls

  A `:function_call` carries its callee in two places: `:name` is a *display*
  string (`"User.find_by"`), and `:receiver` holds the receiver as a real
  MetaAST node (`{:literal, [subtype: :constant], "User"}`). Since Metastatic
  0.44 the receiver is authoritative -- `:name` is a lossy rendering that
  `FromMeta` never parses back, and for a receiver the adapter cannot render it
  is the literal `"obj"`. Call resolution therefore prefers `:receiver` and
  falls back to splitting `:name` only when the node has no receiver (a bare
  call such as `puts`, or MetaAST produced by an older Metastatic).

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
    name_str = meta |> Keyword.get(:name, "unknown") |> coerce_name()
    params = Keyword.get(meta, :params, [])
    visibility = Keyword.get(meta, :visibility, :public)
    line = Keyword.get(meta, :line, 0)
    arity = length(params)

    # A singleton definition (`def self.list`, `def Foo.bar`) is a method of
    # the *receiver*, not of the enclosing container. Metastatic 0.44 carries
    # the receiver node in `:receiver`; a `"self."` prefix on `:name` (the
    # pre-0.44 shape) still resolves through the same helper.
    module = container_for_function(meta, ctx.container, ctx.language)
    func_atom = safe_to_atom(qualified_function_name(name_str, meta))

    func_entry = %{
      name: func_atom,
      arity: arity,
      module: module,
      file: ctx.file,
      line: line,
      doc: nil,
      visibility: visibility,
      metadata: %{params: extract_param_names(params)}
    }

    acc = %{acc | functions: [func_entry | acc.functions]}

    inner_ctx = %{
      ctx
      | function: func_atom,
        arity: arity
    }

    # Walk body with function context
    {body, acc} = walk_list(body, inner_ctx, acc)
    {{:function_def, meta, body}, acc}
  end

  defp walk({:function_call, meta, args}, ctx, acc) when is_list(meta) and is_list(args) do
    name_str = meta |> Keyword.get(:name, "unknown") |> coerce_name()
    line = Keyword.get(meta, :line, 0)
    call_arity = length(args)

    {to_module, to_function} = resolve_call_target(meta, name_str, ctx.language)

    from_module = ctx.container || normalize_module_name("top_level", ctx.language)

    call_entry = %{
      from_module: from_module,
      from_function: ctx.function || :top_level,
      from_arity: ctx.arity || 0,
      # A call on a value receiver (`record&.title`, `@x.foo`) belongs to no
      # module, so it is attributed to the caller's container rather than
      # left dangling on `nil`.
      to_module: to_module || from_module,
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
    source = Keyword.get(meta, :source) || Keyword.get(meta, :module, "unknown")
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
        {nil, safe_to_atom(single)}

      parts ->
        func = List.last(parts)
        mod = parts |> Enum.drop(-1) |> Enum.join(".")
        {normalize_module_name(mod, language), safe_to_atom(func)}
    end
  end

  # Resolves the callee of a `:function_call`.
  #
  # The `:receiver` meta key (Metastatic 0.44+) is authoritative: it holds the
  # receiver as a real MetaAST node, while `:name` is a display string that is
  # lossy for anything the adapter cannot render (it falls back to `"obj"`).
  # When there is no receiver the call is bare, and `:name` is the whole
  # story -- including the legacy `"Module.func"` shape from older MetaAST and
  # from languages whose adapters still flatten qualified names.
  defp resolve_call_target(meta, name_str, language) do
    case Keyword.get(meta, :receiver) do
      nil ->
        split_call_name(name_str, language)

      receiver ->
        {receiver_module(receiver, language), safe_to_atom(bare_call_name(name_str))}
    end
  end

  # Renders a receiver node as a module name, or `nil` when it names no module.
  #
  # Constants (`User`, `Foo::Bar`) are the only receivers that denote a module.
  # A variable, instance variable or nested call receiver (`record&.title`,
  # `@x.foo`, `a.b.c`) is a value, so the call has no module to attribute and
  # the caller's container is used instead.
  defp receiver_module({:literal, meta, name}, language) when is_binary(name) do
    if Keyword.get(meta, :subtype) == :constant do
      normalize_module_name(name, language)
    end
  end

  defp receiver_module({:function_call, meta, _args}, language) do
    # `Foo::Bar.new` arrives as a call whose own receiver is the constant.
    case Keyword.get(meta, :receiver) do
      nil -> nil
      inner -> receiver_module(inner, language)
    end
  end

  defp receiver_module(_receiver, _language), do: nil

  # The trailing segment of a possibly-qualified display name.
  defp bare_call_name(name) when is_binary(name) do
    name |> String.split(".") |> List.last()
  end

  # The container a `:function_def` belongs to.
  #
  # A singleton definition (`def self.list`, `def Foo.bar`) defines a method on
  # the receiver, so a constant receiver names the module. Without one the
  # definition belongs to the enclosing container, falling back to
  # `"top_level"` for a definition outside any container. MetaAST from before
  # Metastatic 0.44 carries no `:receiver`, only a `"self."` prefix on `:name`;
  # that shape still resolves to the enclosing container.
  defp container_for_function(meta, container, language) do
    case Keyword.get(meta, :receiver) do
      nil -> container || "top_level"
      receiver -> receiver_module(receiver, language) || container || "top_level"
    end
  end

  # The bare method name of a `:function_def`.
  #
  # `:name` is a display string (`"self.list"`, `"Foo.bar"`) when the
  # definition has a receiver; the function itself is the trailing segment.
  # The `"self."` prefix of pre-0.44 MetaAST is stripped the same way, so a
  # document produced by either Metastatic version yields the same name.
  defp qualified_function_name(name_str, meta) do
    if Keyword.has_key?(meta, :receiver) or self_prefixed?(name_str) do
      bare_call_name(name_str)
    else
      name_str
    end
  end

  defp self_prefixed?(name) when is_binary(name), do: String.starts_with?(name, "self.")

  # Normalize module names according to language conventions.
  # Elixir: "TestModule" -> Module atom (Elixir.TestModule)
  # Erlang: "my_module" -> :my_module atom
  # Others: kept as strings
  defp normalize_module_name(name, :elixir) when is_binary(name) do
    name
    |> String.split(".")
    |> Enum.map(&safe_to_atom/1)
    |> Module.concat()
  end

  defp normalize_module_name(name, :erlang) when is_binary(name) do
    safe_to_atom(name)
  end

  defp normalize_module_name(name, _language), do: name

  defp extract_param_names(params) do
    Enum.map(params, fn
      {:param, _meta, name} when is_binary(name) -> name
      {:param, _meta, name} when is_atom(name) -> Atom.to_string(name)
      name when is_binary(name) -> name
      name when is_atom(name) -> Atom.to_string(name)
      _ -> "_"
    end)
  end

  # Coerce AST :name values to binaries.
  # Metastatic emits non-string names for pattern-matched function heads,
  # e.g. `defp variable({name, meta, args})` where :name is an AST list.
  defp coerce_name(name) when is_binary(name), do: name
  defp coerce_name(name) when is_atom(name), do: Atom.to_string(name)
  defp coerce_name(name), do: inspect(name)

  @max_atom_length 255

  defp safe_to_atom(atom) when is_atom(atom), do: atom

  defp safe_to_atom(str) when is_binary(str) do
    if String.length(str) > @max_atom_length do
      str |> String.slice(0, @max_atom_length) |> String.to_atom()
    else
      String.to_atom(str)
    end
  end
end
