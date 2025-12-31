defmodule Ragex.Analyzers.Elixir do
  @moduledoc """
  Analyzes Elixir code to extract modules, functions, calls, and dependencies.

  Uses Code.string_to_quoted/2 to parse the AST and traverses it to extract
  relevant information for the knowledge graph.
  """

  @behaviour Ragex.Analyzers.Behaviour

  @impl true
  def analyze(source, file_path) do
    case Code.string_to_quoted(source, file: file_path, columns: true) do
      {:ok, ast} ->
        context = %{
          file: file_path,
          current_module: nil,
          current_function: nil,
          modules: [],
          functions: [],
          calls: [],
          imports: [],
          aliases: %{}  # Track aliases for resolution
        }

        context = traverse_ast(ast, context)

        result = %{
          modules: Enum.reverse(context.modules),
          functions: Enum.reverse(context.functions),
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

    module_info = %{
      name: module_name,
      file: context.file,
      line: line,
      doc: nil,
      metadata: %{}
    }

    context = %{context | current_module: module_name}
    context = %{context | modules: [module_info | context.modules]}

    # Traverse module body
    context = traverse_ast(body, context)

    # Clear aliases when leaving module
    %{context | current_module: nil, aliases: %{}}
  end

  defp traverse_ast({:def, meta, [signature | _]} = node, context) do
    handle_function_def(node, meta, signature, :public, context)
  end

  defp traverse_ast({:defp, meta, [signature | _]} = node, context) do
    handle_function_def(node, meta, signature, :private, context)
  end

  defp traverse_ast({:@, _meta, [{:doc, _, [doc]}]}, context) when is_binary(doc) do
    # Store doc for next function/module (simplified for now)
    context
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

  defp traverse_ast({:alias, _meta, [module_alias | rest]}, context) do
    full_name = extract_module_name(module_alias)
    
    # Determine the alias name (last part of the module or explicit :as option)
    alias_name = 
      case rest do
        [[as: {:__aliases__, _, [name]}]] -> name
        _ -> 
          # Use last part of module name
          case full_name do
            atom when is_atom(atom) ->
              atom |> Atom.to_string() |> String.split(".") |> List.last() |> String.to_atom()
            _ -> :unknown
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
      func_info = %{
        name: name,
        arity: arity,
        module: context.current_module,
        file: context.file,
        line: line,
        doc: nil,
        visibility: visibility,
        metadata: %{}
      }

      context = %{context | functions: [func_info | context.functions]}
      context = %{context | current_function: {name, arity}}

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
          [_single] -> full_module
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
end
