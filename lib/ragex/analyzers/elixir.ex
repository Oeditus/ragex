defmodule Ragex.Analyzers.Elixir do
  @moduledoc """
  Analyzes Elixir code to extract modules, functions, calls, and dependencies.

  Uses Code.string_to_quoted/2 to parse the AST and traverses it to extract
  relevant information for the knowledge graph.
  """

  @behaviour Ragex.Analyzers.Behaviour

  @impl true
  def analyze(source, file_path, opts \\ []) do
    expand_macros = Keyword.get(opts, :expand_macros, :partial)

    # Extract comments from source
    comments = extract_comments(source)

    case Code.string_to_quoted(source, file: file_path, columns: true) do
      {:ok, ast} ->
        # Expand macros based on configuration
        ast =
          case expand_macros do
            :none -> ast
            :partial -> expand_common_macros(ast)
            :full -> expand_with_compilation(ast, file_path)
          end

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
          expand_macros: expand_macros
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
          imports: Enum.reverse(context.imports)
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
    add_import(context, module_alias, :require)
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

            _ ->
              :unknown
          end
      end

    # Store alias in context
    context = %{context | aliases: Map.put(context.aliases, alias_name, full_name)}

    add_import(context, module_alias, :alias)
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

      context = %{context | calls: [call_info | context.calls]}
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

  # Helper functions

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
        metadata: %{}
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

  # Macro Expansion

  # Expand common macros that don't require compilation context
  defp expand_common_macros(ast) do
    Macro.prewalk(ast, fn node ->
      case node do
        # Handle defdelegate
        {:defdelegate, meta, [signature, opts]} ->
          expand_defdelegate(signature, opts, meta)

        # Handle defstruct (extract struct definition)
        {:defstruct, meta, [fields]} ->
          # Keep defstruct as-is but we'll extract info during traversal
          {:defstruct, meta, [fields]}

        # Keep other nodes as-is
        other ->
          other
      end
    end)
  end

  # Expand defdelegate into actual function definition with call
  defp expand_defdelegate(signature, opts, meta) do
    {func_name, func_meta, args} = signature
    target_module = Keyword.get(opts, :to)
    target_func = Keyword.get(opts, :as, func_name)

    # Build argument list for the delegated call
    arg_names =
      case args do
        nil -> []
        args when is_list(args) -> Enum.map(args, fn {name, _, _} -> {name, [], nil} end)
        _ -> []
      end

    # Create a def with a call to the target module
    body =
      if target_module do
        # Generate: TargetModule.target_func(args...)
        {{:., [], [target_module, target_func]}, [], arg_names}
      else
        # If no :to option, just return nil (shouldn't happen in valid code)
        nil
      end

    # Return a def node
    {:def, meta, [{func_name, func_meta, args}, [do: body]]}
  end

  # Expand macros using full compilation (requires compilation environment)
  defp expand_with_compilation(ast, file_path) do
    # Try to expand using Macro.expand/2 in a safe environment
    try do
      # Create a minimal environment for expansion
      env = %Macro.Env{
        file: file_path,
        line: 1,
        module: nil,
        function: nil,
        context: nil,
        requires: [],
        aliases: [],
        functions: [],
        macros: [],
        macro_aliases: [],
        context_modules: [],
        lexical_tracker: nil,
        tracers: []
      }

      # Attempt to expand the entire AST
      Macro.expand(ast, env)
    rescue
      # If expansion fails, fall back to partial expansion
      _ -> expand_common_macros(ast)
    end
  end

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
          comment = find_nearby_comment(mod.line, context.comments, :before)
          if comment, do: %{mod | doc: comment}, else: mod
        else
          mod
        end
      end)

    # Update functions without doc
    updated_functions =
      Enum.map(context.functions, fn func ->
        if is_nil(func.doc) || func.doc == "" do
          comment = find_nearby_comment(func.line, context.comments, :before)
          if comment, do: %{func | doc: comment}, else: func
        else
          func
        end
      end)

    # Update types without typedoc
    updated_types =
      Enum.map(context.types, fn type ->
        if is_nil(type.doc) || type.doc == "" do
          comment = find_nearby_comment(type.line, context.comments, :before)
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

  # Find comment near a specific line
  defp find_nearby_comment(target_line, comments, direction) do
    case direction do
      :before ->
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

      :after ->
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
