defmodule Ragex.Analyzers.Elixir do
  @moduledoc """
  Analyzes Elixir code to extract modules, functions, calls, and dependencies.

  Uses Code.string_to_quoted/2 to parse the AST and traverses it to extract
  relevant information for the knowledge graph.
  """

  @behaviour Ragex.Analyzers.Behaviour

  alias Ragex.Analyzers.Elixir.MacroExpander

  @impl true
  def analyze(source, file_path, opts \\ []) do
    expand_macros = Keyword.get(opts, :expand_macros, :partial)

    # Extract comments from source
    comments = extract_comments(source)

    case Code.string_to_quoted(source, file: file_path, columns: true) do
      {:ok, ast} ->
        # Recover `use` targets before expansion: ExPanda rewrites `use X` into
        # `require X` + the injected body, losing the `:use` edge.
        use_targets = MacroExpander.use_targets(ast)

        # Expand macros based on configuration. `MacroExpander` never raises and
        # returns the AST untouched when expansion is impossible, so the
        # analyzer always makes progress.
        ast = MacroExpander.expand(ast, expand_macros, file: file_path)

        # `@unexpanded` markers are pure diagnostics; leaving them in would
        # make them look like real module attributes to the traversal below.
        unexpanded = MacroExpander.unexpanded(ast)
        ast = MacroExpander.strip_markers(ast)

        context = %{
          file: file_path,
          current_module: nil,
          current_function: nil,
          modules: [],
          functions: [],
          types: [],
          calls: [],
          imports: [],
          # Track aliases for resolution
          aliases: %{},
          # Track pending documentation
          pending_moduledoc: nil,
          pending_doc: nil,
          pending_typedoc: nil,
          pending_spec: nil,
          # Store comments for association
          comments: comments,
          # Track macro expansion mode
          expand_macros: expand_macros,
          # Macros that could not be resolved (confidence signal)
          unexpanded: unexpanded,
          # Modules referenced by `use` in the surface AST (survives expansion)
          use_targets: use_targets
        }

        context = traverse_ast(ast, context)

        # Associate comments with undocumented entities
        context = associate_comments(context)

        # Extract documentation references and links
        context = extract_doc_references(context)

        result = %{
          modules: Enum.reverse(context.modules),
          functions: Enum.reverse(context.functions),
          types: Enum.reverse(context.types),
          calls: Enum.reverse(context.calls),
          imports: Enum.reverse(context.imports),
          unexpanded: context.unexpanded
        }

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def supported_extensions, do: [".ex", ".exs"]

  # AST Traversal

  defp traverse_ast({:defmodule, meta, [module_alias, [do: body]]}, context) do
    module_name = extract_module_name(module_alias)
    line = Keyword.get(meta, :line, 0)

    # Create placeholder module info (will be updated with doc later)
    module_info = %{
      name: module_name,
      file: context.file,
      line: line,
      doc: nil,
      metadata: %{}
    }

    context = %{context | current_module: module_name}
    context = %{context | modules: [module_info | context.modules]}

    # Record `use` edges recovered from the surface AST. Once ExPanda has
    # expanded the module body, `use X` no longer appears as such (it becomes
    # `require X` plus the injected body), so these are added up-front.
    context = add_use_imports(context)

    # Traverse module body - this will encounter @moduledoc
    context = traverse_ast(body, context)

    # Update module with captured moduledoc
    context =
      if context.pending_moduledoc do
        # Find and update the module we just added
        updated_modules =
          context.modules
          |> Enum.map(fn mod ->
            if mod.name == module_name && mod.line == line do
              %{mod | doc: context.pending_moduledoc}
            else
              mod
            end
          end)

        %{context | modules: updated_modules, pending_moduledoc: nil}
      else
        context
      end

    # Clear aliases and pending docs when leaving module
    %{
      context
      | current_module: nil,
        aliases: %{},
        pending_moduledoc: nil,
        pending_doc: nil,
        pending_typedoc: nil,
        pending_spec: nil
    }
  end

  defp traverse_ast({:def, meta, [signature | _]} = node, context) do
    handle_function_def(node, meta, signature, :public, context)
  end

  defp traverse_ast({:defp, meta, [signature | _]} = node, context) do
    handle_function_def(node, meta, signature, :private, context)
  end

  defp traverse_ast({:@, _meta, [{:moduledoc, _, [doc]}]}, context) do
    # Store moduledoc for next module definition
    # Handle both binary strings and false (for @moduledoc false)
    doc_value = if is_binary(doc), do: doc, else: nil
    %{context | pending_moduledoc: doc_value}
  end

  defp traverse_ast({:@, _meta, [{:doc, _, [doc]}]}, context) do
    # Store doc for next function definition
    # Handle both binary strings and false (for @doc false)
    doc_value = if is_binary(doc), do: doc, else: nil
    %{context | pending_doc: doc_value}
  end

  defp traverse_ast({:@, _meta, [{:typedoc, _, [doc]}]}, context) do
    # Store typedoc for next type definition
    doc_value = if is_binary(doc), do: doc, else: nil
    %{context | pending_typedoc: doc_value}
  end

  defp traverse_ast({:@, _meta, [{:spec, _, spec_args}]}, context) do
    # Store spec for next function definition
    # Format: @spec func_name(type1, type2) :: return_type
    spec_string = format_spec(spec_args)
    %{context | pending_spec: spec_string}
  end

  # Handle @type, @typep, @opaque
  defp traverse_ast({:@, meta, [{type_kind, _, [type_def]}]}, context)
       when type_kind in [:type, :typep, :opaque] do
    if context.current_module do
      {type_name, type_spec} = extract_type_info(type_def)
      line = Keyword.get(meta, :line, 0)
      visibility = if type_kind == :typep, do: :private, else: :public

      type_info = %{
        name: type_name,
        module: context.current_module,
        file: context.file,
        line: line,
        kind: type_kind,
        spec: type_spec,
        doc: context.pending_typedoc,
        visibility: visibility,
        metadata: %{}
      }

      context = %{context | types: [type_info | context.types]}
      # Clear pending typedoc after use
      %{context | pending_typedoc: nil}
    else
      context
    end
  end

  defp traverse_ast({:import, _meta, [module_alias | _]}, context) do
    add_import(context, module_alias, :import)
  end

  defp traverse_ast({:require, _meta, [module_alias | _]}, context) do
    # ExPanda expands `use X` into `require X` + the injected body. The `:use`
    # edge is already recorded (from the surface AST via `use_targets/1`), so
    # skip the synthetic `require` to avoid a duplicate edge for the same
    # module. A genuine `require` the user wrote still comes through.
    module = extract_module_name(module_alias)

    if use_import?(context, module) do
      context
    else
      add_import(context, module_alias, :require)
    end
  end

  defp traverse_ast({:use, _meta, [module_alias | _]}, context) do
    add_import(context, module_alias, :use)
  end

  # Handle defstruct - extract struct field information
  defp traverse_ast({:defstruct, meta, [fields]}, context) do
    if context.current_module do
      line = Keyword.get(meta, :line, 0)
      field_list = extract_struct_fields(fields)

      # Store struct info in module metadata (we'll update the current module)
      updated_modules =
        Enum.map(context.modules, fn mod ->
          if mod.name == context.current_module do
            struct_info = %{fields: field_list, line: line}
            %{mod | metadata: Map.put(mod.metadata, :struct, struct_info)}
          else
            mod
          end
        end)

      %{context | modules: updated_modules}
    else
      context
    end
  end

  defp traverse_ast({:alias, _meta, [module_alias | rest]}, context) do
    full_name = extract_module_name(module_alias)

    # Determine the alias name (last part of the module or explicit :as option)
    alias_name =
      case rest do
        [[as: {:__aliases__, _, [name]}]] ->
          name

        _ ->
          # Use last part of module name
          case full_name do
            atom when is_atom(atom) ->
              atom |> Atom.to_string() |> String.split(".") |> List.last() |> String.to_atom()
          end
      end

    # Store alias in context
    context = %{context | aliases: Map.put(context.aliases, alias_name, full_name)}

    add_import(context, module_alias, :alias)
  end

  # Pipe operator: `lhs |> rhs` supplies one extra argument to `rhs`.
  #
  # The surface AST for `data |> Repo.insert()` is
  #   {:|>, _, [{:data, _, nil}, {{:., _, [Repo, :insert]}, _, []}]}
  # -- the remote-call node has ZERO args, so recording `length(args)` yields
  # arity 0 for every piped call in a codebase. Rewrite the pipe into the
  # equivalent direct call before traversal so arity (and nested-call
  # detection) is correct. Only applies when expansion left the pipe in place;
  # with `:partial`/`:full` ExPanda has already desugared it.
  defp traverse_ast({:|>, _meta, [lhs, rhs]}, context) do
    traverse_ast(pipe_to_call(lhs, rhs), context)
  end

  # Function call - simplified detection
  defp traverse_ast({{:., _meta1, [module_alias, func]}, meta2, args}, context)
       when is_atom(func) and is_list(args) do
    if context.current_module && context.current_function do
      line = Keyword.get(meta2, :line, 0)
      module_name = resolve_module_name(module_alias, context)
      arity = length(args)

      call_info = %{
        from_module: context.current_module,
        from_function: elem(context.current_function, 0),
        from_arity: elem(context.current_function, 1),
        to_module: module_name,
        to_function: func,
        to_arity: arity,
        line: line
      }

      context =
        if operator_call?(module_name, func) do
          context
        else
          %{context | calls: [call_info | context.calls]}
        end

      # Continue traversing arguments
      Enum.reduce(args, context, &traverse_ast/2)
    else
      context
    end
  end

  # Traverse tuples
  defp traverse_ast(tuple, context) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(context, &traverse_ast/2)
  end

  # Traverse lists
  defp traverse_ast(list, context) when is_list(list) do
    Enum.reduce(list, context, &traverse_ast/2)
  end

  # Skip atoms, numbers, strings, etc.
  defp traverse_ast(_other, context), do: context

  # Operator forms that macro expansion produces as `:erlang.<op>(...)` calls.
  #
  # `if a == b` desugars to `case :erlang.==(a, b)`, and `&&`/`||` to
  # `:erlang.andalso/orelse`, so expanding control flow injects a large number
  # of `:erlang` "calls" that are not dependencies at all -- they are the
  # compiler's own encoding of an operator. Left in, they dominate the call
  # graph (measured: 114 of 142 `:erlang` edges in the analyzer itself) and
  # drown out the genuine `:erlang` BIFs (`is_binary/1`, `length/1`, ...) that
  # *are* worth recording.
  @operator_functions [
    :"=:=",
    :==,
    :!=,
    :"/=",
    :<,
    :>,
    :"=<",
    :>=,
    :+,
    :-,
    :*,
    :/,
    :++,
    :--,
    :andalso,
    :orelse,
    :not,
    :and,
    :or,
    :xor,
    :!
  ]

  # True when the call is an operator encoding rather than a real dependency.
  defp operator_call?(:erlang, fun), do: fun in @operator_functions
  defp operator_call?(_module, _fun), do: false
  # Helper functions

  # Rewrites `lhs |> f(a)` into `f(lhs, a)` so the call is recorded with the
  # arity the user actually wrote. Handles both remote (`Mod.f/1`) and local
  # (`f/1`) right-hand sides; anything else is passed through untouched so the
  # generic tuple/list clauses still walk it.
  defp pipe_to_call(lhs, {{:., dot_meta, [mod, fun]}, call_meta, args}) when is_list(args) do
    {{:., dot_meta, [mod, fun]}, call_meta, [lhs | args]}
  end

  defp pipe_to_call(lhs, {fun, call_meta, args}) when is_atom(fun) and is_list(args) do
    {fun, call_meta, [lhs | args]}
  end

  defp pipe_to_call(lhs, rhs), do: {:|>, [], [lhs, rhs]}

  # Emits `:use` import edges for the module currently being traversed.
  # `:none` mode never expands, so the surface `use` nodes are still present and
  # the normal `traverse_ast({:use, ...})` clause records them; adding them here
  # too would duplicate the edge.
  defp add_use_imports(%{expand_macros: :none} = context), do: context

  defp add_use_imports(context) do
    Enum.reduce(context.use_targets, context, fn target, acc ->
      add_import(acc, target, :use)
    end)
  end

  # True when a `:use` edge for `module` has already been recorded for the
  # module currently being traversed.
  defp use_import?(context, module) do
    Enum.any?(context.imports, fn
      %{type: :use, to_module: ^module, from_module: from} -> from == context.current_module
      _ -> false
    end)
  end

  # Distinguishes user-authored definitions from ones a `use` macro injected.
  #
  # ExPanda preserves `:line` metadata on definitions the user actually wrote
  # (it walks the surface AST) but the definitions it synthesises from a
  # `__using__/1` quote carry no line. Recording that lets callers filter
  # phantom functions out of "what does this module define?" answers while
  # still being able to see the injected ones when they are useful (e.g.
  # `child_spec/1` proving a module is a supervisor child).
  defp def_metadata(meta) do
    case Keyword.get(meta, :line) do
      line when is_integer(line) and line > 0 -> %{injected: false}
      _ -> %{injected: true}
    end
  end

  defp handle_function_def(
         {_def_type, _meta, [_signature, body_block]},
         meta,
         signature,
         visibility,
         context
       ) do
    {name, arity} = extract_function_signature(signature)
    line = Keyword.get(meta, :line, 0)

    if context.current_module do
      # Attach pending doc and spec if available
      doc = context.pending_doc
      spec = context.pending_spec

      func_info = %{
        name: name,
        arity: arity,
        module: context.current_module,
        file: context.file,
        line: line,
        doc: doc,
        spec: spec,
        visibility: visibility,
        metadata: def_metadata(meta)
      }

      context = %{context | functions: [func_info | context.functions]}
      context = %{context | current_function: {name, arity}}
      # Clear pending doc and spec after use
      context = %{context | pending_doc: nil, pending_spec: nil}

      # Traverse function body (not the entire def node to avoid infinite recursion)
      body =
        case body_block do
          [do: body_ast] -> body_ast
          _ -> body_block
        end

      context = traverse_ast(body, context)

      %{context | current_function: nil}
    else
      context
    end
  end

  defp handle_function_def(_node, _meta, _signature, _visibility, context) do
    # Fallback for unexpected function def structures
    context
  end

  defp extract_function_signature({:when, _meta, [signature | _]}),
    do: extract_function_signature(signature)

  defp extract_function_signature({name, _meta, args}) when is_atom(name) do
    arity =
      case args do
        nil -> 0
        args when is_list(args) -> length(args)
        _ -> 0
      end

    {name, arity}
  end

  defp extract_function_signature(_), do: {:unknown, 0}

  defp extract_module_name({:__aliases__, _meta, parts}), do: Module.concat(parts)
  defp extract_module_name(atom) when is_atom(atom), do: atom
  defp extract_module_name(_), do: :unknown

  # Resolve module name, checking aliases first
  defp resolve_module_name({:__aliases__, _meta, [first | _rest] = parts}, context) do
    # Check if first part is an alias
    case Map.get(context.aliases, first) do
      nil ->
        # Not an alias, use as-is
        Module.concat(parts)

      full_module ->
        # It's an alias - if there's only one part, use the full module
        # If there are multiple parts, append them to the aliased module
        case parts do
          [_single] ->
            full_module

          [_first | rest] ->
            # Concatenate the aliased module with the rest of the path
            full_str = Atom.to_string(full_module)
            rest_str = Enum.join(rest, ".")
            String.to_atom("#{full_str}.#{rest_str}")
        end
    end
  end

  defp resolve_module_name(atom, _context) when is_atom(atom), do: atom
  defp resolve_module_name(other, _context), do: extract_module_name(other)

  defp add_import(context, module_alias, type) do
    if context.current_module do
      import_info = %{
        from_module: context.current_module,
        to_module: extract_module_name(module_alias),
        type: type
      }

      %{context | imports: [import_info | context.imports]}
    else
      context
    end
  end

  # Extract type name and spec from type definition AST
  defp extract_type_info({:"::", _meta, [name_part, type_spec]}) do
    name = extract_type_name(name_part)
    spec_string = format_type_spec(type_spec)
    {name, spec_string}
  end

  defp extract_type_info(other) do
    # Fallback for unexpected structures
    {:unknown, inspect(other)}
  end

  defp extract_type_name({name, _meta, _args}) when is_atom(name), do: name
  defp extract_type_name(_), do: :unknown

  # Format type spec to string representation
  defp format_type_spec(ast) do
    # Use Macro.to_string for basic formatting
    Macro.to_string(ast)
  rescue
    _ -> inspect(ast)
  end

  # Format spec to string representation
  defp format_spec(spec_args) do
    case spec_args do
      [spec_ast] -> Macro.to_string(spec_ast)
      _ -> inspect(spec_args)
    end
  rescue
    _ -> inspect(spec_args)
  end

  # Extract struct field names and default values
  defp extract_struct_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      # Field with default value: field: value
      {field, default} when is_atom(field) ->
        %{name: field, default: inspect(default)}

      # Field without default value: just :field
      field when is_atom(field) ->
        %{name: field, default: nil}

      _ ->
        %{name: :unknown, default: nil}
    end)
  end

  defp extract_struct_fields(_), do: []

  # Macro expansion is handled by `Ragex.Analyzers.Elixir.MacroExpander`, which
  # delegates to ExPanda. It supersedes the previous hand-rolled `defdelegate`
  # rewrite and the `expand_with_compilation/2` stub (which built a `%Macro.Env{}`
  # with no requires/aliases/macros, so `Macro.expand/2` returned the AST
  # unchanged -- `:full` was silently identical to `:none`).
  #
  # ExPanda 0.3.0 also expands `defdelegate` natively (0.2.x raised inside
  # `:elixir_bootstrap.def/2`), so the manual rewrite that used to live here is
  # gone.

  # Extract comments from source code
  defp extract_comments(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {line, line_num}, acc ->
      case Regex.run(~r/^\s*#\s*(.*)$/, line) do
        [_, comment_text] ->
          [{line_num, String.trim(comment_text)} | acc]

        nil ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  # Associate comments with undocumented entities
  defp associate_comments(context) do
    # Update modules without moduledoc
    updated_modules =
      Enum.map(context.modules, fn mod ->
        if is_nil(mod.doc) || mod.doc == "" do
          comment = find_nearby_comment(mod.line, context.comments)
          if comment, do: %{mod | doc: comment}, else: mod
        else
          mod
        end
      end)

    # Update functions without doc
    updated_functions =
      Enum.map(context.functions, fn func ->
        if is_nil(func.doc) || func.doc == "" do
          comment = find_nearby_comment(func.line, context.comments)
          if comment, do: %{func | doc: comment}, else: func
        else
          func
        end
      end)

    # Update types without typedoc
    updated_types =
      Enum.map(context.types, fn type ->
        if is_nil(type.doc) || type.doc == "" do
          comment = find_nearby_comment(type.line, context.comments)
          if comment, do: %{type | doc: comment}, else: type
        else
          type
        end
      end)

    %{
      context
      | modules: updated_modules,
        functions: updated_functions,
        types: updated_types
    }
  end

  defp find_nearby_comment(target_line, comments) do
    with nil <- find_nearby_comment(target_line, comments, :before),
         do: find_nearby_comment(target_line, comments, :after)
  end

  # Find comment near a specific line
  defp find_nearby_comment(target_line, comments, :before) do
    # Look for comments 1-3 lines before
    comments
    |> Enum.filter(fn {line, _text} ->
      line < target_line && target_line - line <= 3
    end)
    |> Enum.sort_by(fn {line, _text} -> -line end)
    |> case do
      [{_line, text} | _] -> text
      [] -> nil
    end
  end

  defp find_nearby_comment(target_line, comments, :after) do
    # Look for comments 0-2 lines after
    comments
    |> Enum.filter(fn {line, _text} ->
      line >= target_line && line - target_line <= 2
    end)
    |> Enum.sort_by(fn {line, _text} -> line end)
    |> case do
      [{_line, text} | _] -> text
      [] -> nil
    end
  end

  # Extract references from documentation
  defp extract_doc_references(context) do
    # Build a lookup of all entities for reference matching
    all_modules = MapSet.new(context.modules, & &1.name)
    all_functions = MapSet.new(context.functions, fn f -> {f.module, f.name, f.arity} end)
    all_types = MapSet.new(context.types, fn t -> {t.module, t.name} end)

    # Update modules with extracted references
    updated_modules =
      Enum.map(context.modules, fn mod ->
        if mod.doc && is_binary(mod.doc) do
          refs = parse_doc_references(mod.doc, all_modules, all_functions, all_types)
          %{mod | metadata: Map.put(mod.metadata, :references, refs)}
        else
          mod
        end
      end)

    # Update functions with extracted references
    updated_functions =
      Enum.map(context.functions, fn func ->
        if func.doc && is_binary(func.doc) do
          refs = parse_doc_references(func.doc, all_modules, all_functions, all_types)
          %{func | metadata: Map.put(func.metadata, :references, refs)}
        else
          func
        end
      end)

    # Update types with extracted references
    updated_types =
      Enum.map(context.types, fn type ->
        if type.doc && is_binary(type.doc) do
          refs = parse_doc_references(type.doc, all_modules, all_functions, all_types)
          %{type | metadata: Map.put(type.metadata, :references, refs)}
        else
          type
        end
      end)

    %{
      context
      | modules: updated_modules,
        functions: updated_functions,
        types: updated_types
    }
  end

  # Parse documentation text for references
  defp parse_doc_references(doc_text, modules, functions, _types) do
    references = []

    # Extract backtick-quoted code references like `MyModule.my_func/2`
    code_refs =
      Regex.scan(~r/`([A-Z][A-Za-z0-9_.]*)(?:\.([a-z_][a-z0-9_?!]*))?(?:\/([0-9]+))?`/, doc_text)
      |> Enum.map(fn
        [_, module_str, func_str, arity_str] when func_str != "" and arity_str != "" ->
          module = String.to_existing_atom(module_str)
          func = String.to_existing_atom(func_str)
          arity = String.to_integer(arity_str)

          if MapSet.member?(functions, {module, func, arity}) do
            %{type: :function, module: module, name: func, arity: arity}
          else
            nil
          end

        [_, module_str, "", ""] ->
          module = String.to_existing_atom(module_str)

          if MapSet.member?(modules, module) do
            %{type: :module, name: module}
          else
            nil
          end

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    references = references ++ code_refs

    # Extract @see tags
    see_refs =
      Regex.scan(
        ~r/@see\s+([A-Z][A-Za-z0-9_.]*)(?:\.([a-z_][a-z0-9_?!]*))?(?:\/([0-9]+))?/,
        doc_text
      )
      |> Enum.map(fn
        [_, module_str, func_str, arity_str] when func_str != "" and arity_str != "" ->
          module = String.to_existing_atom(module_str)
          func = String.to_existing_atom(func_str)
          arity = String.to_integer(arity_str)

          if MapSet.member?(functions, {module, func, arity}) do
            %{type: :function, module: module, name: func, arity: arity, tag: :see}
          else
            nil
          end

        [_, module_str, "", ""] ->
          module = String.to_existing_atom(module_str)

          if MapSet.member?(modules, module) do
            %{type: :module, name: module, tag: :see}
          else
            nil
          end

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    references = references ++ see_refs

    Enum.uniq(references)
  rescue
    # If any atom conversion fails, return empty list
    _ -> []
  end
end
