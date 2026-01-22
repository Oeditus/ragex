defmodule Ragex.Editor.Refactor.Elixir do
  @moduledoc """
  Elixir-specific AST manipulation for semantic refactoring.

  Provides functions to rename functions and modules by parsing and
  transforming Elixir AST, preserving comments and formatting where possible.
  """

  require Logger

  @doc """
  Renames a function definition and all its calls within a source file.

  ## Parameters
  - `content`: Source code as string
  - `old_name`: Current function name (atom or string)
  - `new_name`: New function name (atom or string)
  - `arity`: Function arity (nil to rename all arities)

  ## Returns
  - `{:ok, new_content}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> content = "def old_func(x), do: x + 1"
      iex> Elixir.rename_function(content, :old_func, :new_func, 1)
      {:ok, "def new_func(x), do: x + 1"}
  """
  @spec rename_function(
          String.t(),
          atom() | String.t(),
          atom() | String.t(),
          non_neg_integer() | nil
        ) ::
          {:ok, String.t()} | {:error, term()}
  def rename_function(content, old_name, new_name, arity \\ nil) do
    old_atom = to_atom(old_name)
    new_atom = to_atom(new_name)

    with {:ok, ast} <- parse_code(content),
         transformed_ast <- transform_function_names(ast, old_atom, new_atom, arity),
         {:ok, new_content} <- ast_to_string(transformed_ast) do
      {:ok, new_content}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Renames a module and all references to it.

  ## Parameters
  - `content`: Source code as string
  - `old_name`: Current module name (atom or string)
  - `new_name`: New module name (atom or string)

  ## Returns
  - `{:ok, new_content}` on success
  - `{:error, reason}` on failure
  """
  @spec rename_module(String.t(), atom() | String.t(), atom() | String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def rename_module(content, old_name, new_name) do
    old_atom = to_atom(old_name)
    new_atom = to_atom(new_name)

    with {:ok, ast} <- parse_code(content),
         transformed_ast <- transform_module_names(ast, old_atom, new_atom),
         {:ok, new_content} <- ast_to_string(transformed_ast) do
      {:ok, new_content}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Finds all function calls to a specific function in the AST.

  Returns a list of line numbers where the function is called.
  """
  @spec find_function_calls(String.t(), atom() | String.t(), non_neg_integer() | nil) ::
          {:ok, [non_neg_integer()]} | {:error, term()}
  def find_function_calls(content, function_name, arity \\ nil) do
    function_atom = to_atom(function_name)

    with {:ok, ast} <- parse_code(content) do
      lines = collect_call_lines(ast, function_atom, arity)
      {:ok, lines}
    end
  end

  # Private functions

  defp parse_code(content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {_meta, message, _token}} when is_binary(message) ->
        {:error, "Parse error: #{message}"}

      {:error, {_meta, {_line, _col, message}, _token}} ->
        {:error, "Parse error: #{message}"}

      {:error, reason} ->
        {:error, "Parse error: #{inspect(reason)}"}
    end
  end

  defp ast_to_string(ast) do
    # Use Macro.to_string for basic conversion
    code = Macro.to_string(ast)
    {:ok, code}
  rescue
    e ->
      {:error, "Failed to convert AST to string: #{inspect(e)}"}
  end

  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value) when is_binary(value), do: String.to_atom(value)

  # Transform function definitions and calls
  defp transform_function_names(ast, old_name, new_name, target_arity) do
    Macro.prewalk(ast, fn node ->
      transform_function_node(node, old_name, new_name, target_arity)
    end)
  end

  defp transform_function_node(node, old_name, new_name, target_arity) do
    case node do
      {:def, meta, [{^old_name, call_meta, args} = _call, body]} when is_list(args) ->
        maybe_rename_def(node, meta, call_meta, args, body, new_name, target_arity)

      {:defp, meta, [{^old_name, call_meta, args} = _call, body]} when is_list(args) ->
        maybe_rename_defp(node, meta, call_meta, args, body, new_name, target_arity)

      {^old_name, meta, args} when is_list(args) ->
        maybe_rename_call(node, meta, args, new_name, target_arity)

      {{:., dot_meta, [module, ^old_name]}, call_meta, args} when is_list(args) ->
        maybe_rename_qualified_call(
          node,
          dot_meta,
          module,
          new_name,
          call_meta,
          args,
          target_arity
        )

      {:&, meta, [{:/, slash_meta, [{^old_name, name_meta, context}, arity]}]}
      when is_integer(arity) ->
        maybe_rename_function_ref(
          node,
          meta,
          slash_meta,
          new_name,
          name_meta,
          context,
          arity,
          target_arity
        )

      _ ->
        node
    end
  end

  defp maybe_rename_def(node, meta, call_meta, args, body, new_name, target_arity) do
    if arity_matches?(args, target_arity) do
      {:def, meta, [{new_name, call_meta, args}, body]}
    else
      node
    end
  end

  defp maybe_rename_defp(node, meta, call_meta, args, body, new_name, target_arity) do
    if arity_matches?(args, target_arity) do
      {:defp, meta, [{new_name, call_meta, args}, body]}
    else
      node
    end
  end

  defp maybe_rename_call(node, meta, args, new_name, target_arity) do
    if arity_matches?(args, target_arity) do
      {new_name, meta, args}
    else
      node
    end
  end

  defp maybe_rename_qualified_call(
         node,
         dot_meta,
         module,
         new_name,
         call_meta,
         args,
         target_arity
       ) do
    if arity_matches?(args, target_arity) do
      {{:., dot_meta, [module, new_name]}, call_meta, args}
    else
      node
    end
  end

  defp maybe_rename_function_ref(
         node,
         meta,
         slash_meta,
         new_name,
         name_meta,
         context,
         arity,
         target_arity
       ) do
    if target_arity == nil or arity == target_arity do
      {:&, meta, [{:/, slash_meta, [{new_name, name_meta, context}, arity]}]}
    else
      node
    end
  end

  defp arity_matches?(_args, nil), do: true
  defp arity_matches?(args, target_arity), do: length(args) == target_arity

  # Transform module names
  defp transform_module_names(ast, old_name, new_name) do
    Macro.prewalk(ast, fn node ->
      case node do
        # Module definition: defmodule OldName
        {:defmodule, meta, [{:__aliases__, alias_meta, segments}, body]} ->
          new_segments = replace_module_segments(segments, old_name, new_name)
          {:defmodule, meta, [{:__aliases__, alias_meta, new_segments}, body]}

        # Alias: alias OldName
        {:alias, meta, [{:__aliases__, alias_meta, segments}]} ->
          new_segments = replace_module_segments(segments, old_name, new_name)
          {:alias, meta, [{:__aliases__, alias_meta, new_segments}]}

        # Module reference in code: OldName.function()
        {:__aliases__, meta, segments} ->
          new_segments = replace_module_segments(segments, old_name, new_name)
          {:__aliases__, meta, new_segments}

        _ ->
          node
      end
    end)
  end

  defp replace_module_segments(segments, old_name, new_name) do
    old_parts = split_module_name(old_name)
    new_parts = split_module_name(new_name)

    # If the segments match the old module path, replace with new
    if segments == old_parts do
      new_parts
    else
      segments
    end
  end

  defp split_module_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
  end

  @doc """
  Extracts a range of lines from a function into a new function.

  ## Parameters
  - `content`: Source code as string
  - `module_name`: Module containing the function
  - `source_function`: Function to extract from
  - `source_arity`: Arity of source function
  - `new_function_name`: Name for the extracted function
  - `line_range`: {start_line, end_line} tuple (1-indexed)
  - `opts`: Options
    - `:placement` - :after_source | :before_source | :end_of_module (default: :after_source)
    - `:visibility` - :public | :private (default: :private)
    - `:add_doc` - boolean (default: false)

  ## Returns
  - `{:ok, new_content}` on success
  - `{:error, reason}` on failure
  """
  @spec extract_function(
          String.t(),
          atom(),
          atom(),
          non_neg_integer(),
          atom(),
          {pos_integer(), pos_integer()},
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def extract_function(
        content,
        _module_name,
        source_function,
        source_arity,
        new_function_name,
        {start_line, end_line},
        opts \\ []
      ) do
    placement = Keyword.get(opts, :placement, :after_source)
    visibility = Keyword.get(opts, :visibility, :private)
    add_doc = Keyword.get(opts, :add_doc, false)

    with {:ok, ast} <- parse_code(content),
         {:ok, extracted_info} <-
           extract_code_block(ast, source_function, source_arity, start_line, end_line),
         {:ok, transformed_ast} <-
           apply_extraction(
             ast,
             extracted_info,
             new_function_name,
             placement,
             visibility,
             add_doc
           ),
         {:ok, new_content} <- ast_to_string(transformed_ast) do
      {:ok, new_content}
    else
      {:error, _reason} = error -> error
    end
  end

  # Extract code block and analyze free variables
  defp extract_code_block(ast, source_function, source_arity, start_line, end_line) do
    # Find the source function definition
    case find_function_definition(ast, source_function, source_arity) do
      nil ->
        {:error, "Function #{source_function}/#{source_arity} not found"}

      {_def_type, function_ast, function_body} ->
        # Extract the lines within the range from the function body
        extracted_nodes = extract_body_lines(function_body, start_line, end_line)

        if Enum.empty?(extracted_nodes) do
          {:error, "No code found in specified line range"}
        else
          # Analyze free variables (used but not defined in extracted code)
          free_vars = analyze_free_variables(extracted_nodes, function_ast)

          {:ok,
           %{
             extracted_nodes: extracted_nodes,
             free_vars: free_vars,
             source_function: source_function,
             source_arity: source_arity,
             start_line: start_line,
             end_line: end_line
           }}
        end
    end
  end

  # Find function definition in AST
  defp find_function_definition(ast, function_name, arity) do
    result =
      Macro.prewalk(ast, nil, fn node, acc ->
        case acc do
          nil ->
            case node do
              {:def, _meta, [{^function_name, _call_meta, args}, body]} when is_list(args) ->
                if length(args) == arity do
                  {node, {:def, node, body}}
                else
                  {node, nil}
                end

              {:defp, _meta, [{^function_name, _call_meta, args}, body]} when is_list(args) ->
                if length(args) == arity do
                  {node, {:defp, node, body}}
                else
                  {node, nil}
                end

              _ ->
                {node, nil}
            end

          found ->
            {node, found}
        end
      end)

    case result do
      {_ast, found} -> found
      _ -> nil
    end
  end

  # Extract nodes within line range from function body
  defp extract_body_lines(body, start_line, end_line) do
    {_ast, extracted} =
      Macro.prewalk(body, [], fn node, acc ->
        meta = extract_meta(node)
        line = Keyword.get(meta, :line)

        if line && line >= start_line && line <= end_line do
          {node, [node | acc]}
        else
          {node, acc}
        end
      end)

    Enum.reverse(extracted)
  end

  defp extract_meta({_form, meta, _args}) when is_list(meta), do: meta
  defp extract_meta(_), do: []

  # Analyze free variables in extracted code
  defp analyze_free_variables(extracted_nodes, function_ast) do
    # Get all variables used in extracted nodes
    used_vars = collect_variables(extracted_nodes)

    # Get parameters from function definition
    defined_vars = collect_function_params(function_ast)

    # Get variables defined within extracted code
    locally_defined = collect_local_definitions(extracted_nodes)

    # Free variables = used - (parameters + locally defined)
    used_vars
    |> MapSet.difference(MapSet.new(defined_vars))
    |> MapSet.difference(MapSet.new(locally_defined))
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp collect_variables(nodes) do
    {_ast, vars} =
      Enum.reduce(nodes, {nil, MapSet.new()}, fn node, {_, acc} ->
        Macro.prewalk(node, acc, fn n, vars_acc ->
          case n do
            {var_name, _meta, context}
            when is_atom(var_name) and is_atom(context) and
                   var_name not in [:__MODULE__, :__ENV__, :__CALLER__] ->
              # Skip Elixir special forms and capitalized atoms
              if String.match?(Atom.to_string(var_name), ~r/^[a-z_]/) do
                {n, MapSet.put(vars_acc, var_name)}
              else
                {n, vars_acc}
              end

            _ ->
              {n, vars_acc}
          end
        end)
      end)

    vars
  end

  defp collect_function_params(function_ast) do
    case function_ast do
      {:def, _meta, [{_name, _call_meta, args}, _body]} when is_list(args) ->
        extract_param_names(args)

      {:defp, _meta, [{_name, _call_meta, args}, _body]} when is_list(args) ->
        extract_param_names(args)

      _ ->
        []
    end
  end

  defp extract_param_names(args) do
    Enum.flat_map(args, fn arg ->
      case arg do
        {name, _meta, context} when is_atom(name) and is_atom(context) -> [name]
        _ -> []
      end
    end)
  end

  defp collect_local_definitions(nodes) do
    {_ast, defs} =
      Enum.reduce(nodes, {nil, MapSet.new()}, fn node, {_, acc} ->
        Macro.prewalk(node, acc, fn n, defs_acc ->
          case n do
            # Match patterns
            {:=, _meta, [pattern, _value]} ->
              vars = extract_pattern_vars(pattern)
              {n, MapSet.union(defs_acc, MapSet.new(vars))}

            # Case clauses
            {:->, _meta, [[pattern | _], _body]} ->
              vars = extract_pattern_vars(pattern)
              {n, MapSet.union(defs_acc, MapSet.new(vars))}

            _ ->
              {n, defs_acc}
          end
        end)
      end)

    MapSet.to_list(defs)
  end

  defp extract_pattern_vars(pattern) do
    {_ast, vars} =
      Macro.prewalk(pattern, [], fn node, acc ->
        case node do
          {name, _meta, context} when is_atom(name) and is_atom(context) ->
            if String.match?(Atom.to_string(name), ~r/^[a-z_]/) do
              {node, [name | acc]}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)

    Enum.reverse(vars)
  end

  # Apply extraction transformation to AST
  defp apply_extraction(
         ast,
         extracted_info,
         new_function_name,
         placement,
         visibility,
         add_doc
       ) do
    %{
      extracted_nodes: extracted_nodes,
      free_vars: free_vars,
      source_function: source_function,
      source_arity: source_arity,
      start_line: start_line,
      end_line: end_line
    } = extracted_info

    # Build the new function
    new_function_def =
      build_extracted_function(
        new_function_name,
        free_vars,
        extracted_nodes,
        visibility,
        add_doc
      )

    # Build the replacement call
    replacement_call = build_replacement_call(new_function_name, free_vars)

    # Transform the AST: replace extracted code with call, insert new function
    transformed_ast =
      ast
      |> replace_extracted_code(
        source_function,
        source_arity,
        start_line,
        end_line,
        replacement_call
      )
      |> insert_new_function(source_function, source_arity, new_function_def, placement)

    {:ok, transformed_ast}
  end

  defp build_extracted_function(name, params, body_nodes, visibility, add_doc) do
    # Build parameter list
    param_asts =
      Enum.map(params, fn param_name ->
        {param_name, [], nil}
      end)

    # Combine body nodes
    body_ast =
      case body_nodes do
        [single] -> single
        multiple -> {:__block__, [], multiple}
      end

    # Build function definition
    def_type = if visibility == :public, do: :def, else: :defp

    function_def = {def_type, [], [{name, [], param_asts}, [do: body_ast]]}

    # Add documentation if requested
    if add_doc && visibility == :public do
      doc_ast = {:@, [], [{:doc, [], ["TODO: Document this function"]}]}
      {:__block__, [], [doc_ast, function_def]}
    else
      function_def
    end
  end

  defp build_replacement_call(function_name, args) do
    arg_asts =
      Enum.map(args, fn arg_name ->
        {arg_name, [], nil}
      end)

    {function_name, [], arg_asts}
  end

  defp replace_extracted_code(
         ast,
         source_function,
         source_arity,
         start_line,
         end_line,
         replacement
       ) do
    Macro.prewalk(ast, fn node ->
      case node do
        {:def, meta, [{^source_function, call_meta, args}, body]} when is_list(args) ->
          if length(args) == source_arity do
            new_body = replace_in_body(body, start_line, end_line, replacement)
            {:def, meta, [{source_function, call_meta, args}, new_body]}
          else
            node
          end

        {:defp, meta, [{^source_function, call_meta, args}, body]} when is_list(args) ->
          if length(args) == source_arity do
            new_body = replace_in_body(body, start_line, end_line, replacement)
            {:defp, meta, [{source_function, call_meta, args}, new_body]}
          else
            node
          end

        _ ->
          node
      end
    end)
  end

  defp replace_in_body(body, start_line, end_line, replacement) do
    case body do
      {:__block__, meta, statements} ->
        # Filter out nodes in the extracted range, keep others
        {new_statements, found} =
          Enum.reduce(statements, {[], false}, fn stmt, {acc, replaced} ->
            stmt_meta = extract_meta(stmt)
            line = Keyword.get(stmt_meta, :line)

            cond do
              replaced ->
                # Already replaced, keep subsequent statements
                {acc ++ [stmt], true}

              line && line >= start_line && line <= end_line ->
                # This is within extraction range
                if line == start_line do
                  # Replace first occurrence with the call
                  {acc ++ [replacement], true}
                else
                  # Skip subsequent nodes in range
                  {acc, false}
                end

              true ->
                # Keep nodes outside range
                {acc ++ [stmt], false}
            end
          end)

        # Ensure we insert replacement even if no exact match
        final_statements = if found, do: new_statements, else: new_statements ++ [replacement]

        {:__block__, meta, final_statements}

      [do: do_block] ->
        [do: replace_in_body(do_block, start_line, end_line, replacement)]

      single_expr ->
        # Single expression body
        expr_meta = extract_meta(single_expr)
        line = Keyword.get(expr_meta, :line)

        if line && line >= start_line && line <= end_line do
          replacement
        else
          single_expr
        end
    end
  end

  defp insert_new_function(ast, source_function, source_arity, new_function_def, placement) do
    case placement do
      :after_source ->
        insert_after_function(ast, source_function, source_arity, new_function_def)

      :before_source ->
        insert_before_function(ast, source_function, source_arity, new_function_def)

      :end_of_module ->
        insert_at_module_end(ast, new_function_def)
    end
  end

  defp insert_after_function(ast, source_function, source_arity, new_function_def) do
    Macro.prewalk(ast, fn node ->
      case node do
        {:defmodule, meta,
         [{module_name, module_meta, _}, [do: {:__block__, block_meta, statements}]]} ->
          new_statements =
            insert_after_in_list(statements, source_function, source_arity, new_function_def)

          {:defmodule, meta,
           [{module_name, module_meta, nil}, [do: {:__block__, block_meta, new_statements}]]}

        _ ->
          node
      end
    end)
  end

  defp insert_before_function(ast, source_function, source_arity, new_function_def) do
    Macro.prewalk(ast, fn node ->
      case node do
        {:defmodule, meta,
         [{module_name, module_meta, _}, [do: {:__block__, block_meta, statements}]]} ->
          new_statements =
            insert_before_in_list(statements, source_function, source_arity, new_function_def)

          {:defmodule, meta,
           [{module_name, module_meta, nil}, [do: {:__block__, block_meta, new_statements}]]}

        _ ->
          node
      end
    end)
  end

  defp insert_at_module_end(ast, new_function_def) do
    Macro.prewalk(ast, fn node ->
      case node do
        {:defmodule, meta,
         [{module_name, module_meta, _}, [do: {:__block__, block_meta, statements}]]} ->
          new_statements = statements ++ [new_function_def]

          {:defmodule, meta,
           [{module_name, module_meta, nil}, [do: {:__block__, block_meta, new_statements}]]}

        _ ->
          node
      end
    end)
  end

  defp insert_after_in_list(statements, source_function, source_arity, new_function_def) do
    {before, after_and_target} =
      Enum.split_while(statements, fn stmt ->
        not matches_function_def?(stmt, source_function, source_arity)
      end)

    case after_and_target do
      [] ->
        # Function not found, append at end
        statements ++ [new_function_def]

      [target | after_target] ->
        # Insert after the target function
        before ++ [target, new_function_def | after_target]
    end
  end

  defp insert_before_in_list(statements, source_function, source_arity, new_function_def) do
    {before, after_and_target} =
      Enum.split_while(statements, fn stmt ->
        not matches_function_def?(stmt, source_function, source_arity)
      end)

    case after_and_target do
      [] ->
        # Function not found, append at end
        statements ++ [new_function_def]

      [target | after_target] ->
        # Insert before the target function
        before ++ [new_function_def, target | after_target]
    end
  end

  defp matches_function_def?(stmt, function_name, arity) do
    case stmt do
      {:def, _meta, [{^function_name, _call_meta, args}, _body]} when is_list(args) ->
        length(args) == arity

      {:defp, _meta, [{^function_name, _call_meta, args}, _body]} when is_list(args) ->
        length(args) == arity

      _ ->
        false
    end
  end

  @doc """
  Inlines a function by replacing all its calls with the function body.

  ## Parameters
  - `content`: Source code as string
  - `module_name`: Module containing the function
  - `function_name`: Function to inline
  - `arity`: Function arity
  - `opts`: Options
    - `:remove_definition` - Remove function definition after inlining (default: true)

  ## Returns
  - `{:ok, new_content}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> content = \"""
      ...> defmodule Test do
      ...>   defp helper(x), do: x * 2
      ...>   def main(a), do: helper(a) + 1
      ...> end
      ...> \"""
      iex> Elixir.inline_function(content, :Test, :helper, 1)
      {:ok, "defmodule Test do\n  def main(a), do: a * 2 + 1\nend"}
  """
  @spec inline_function(
          String.t(),
          atom(),
          atom(),
          non_neg_integer(),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def inline_function(content, _module_name, function_name, arity, opts \\ []) do
    remove_definition = Keyword.get(opts, :remove_definition, true)

    with {:ok, ast} <- parse_code(content),
         {:ok, function_info} <- extract_function_info(ast, function_name, arity),
         {:ok, transformed_ast} <- apply_inlining(ast, function_info, remove_definition),
         {:ok, new_content} <- ast_to_string(transformed_ast) do
      {:ok, new_content}
    else
      {:error, _reason} = error -> error
    end
  end

  # Extract function definition information for inlining
  defp extract_function_info(ast, function_name, arity) do
    case find_function_definition(ast, function_name, arity) do
      nil ->
        {:error, "Function #{function_name}/#{arity} not found"}

      {def_type, function_ast, _function_body} ->
        # Extract parameters and body
        case function_ast do
          {^def_type, _meta, [{^function_name, _call_meta, params}, body_clause]} ->
            # Check for multi-clause functions
            is_multi_clause = multi_clause_function?(ast, function_name, arity)

            if is_multi_clause do
              {:error, "Cannot inline multi-clause functions"}
            else
              param_names = extract_param_names(params)
              body = extract_do_block(body_clause)

              {:ok,
               %{
                 function_name: function_name,
                 arity: arity,
                 params: param_names,
                 body: body,
                 def_type: def_type
               }}
            end

          _ ->
            {:error, "Invalid function structure"}
        end
    end
  end

  defp multi_clause_function?(ast, function_name, arity) do
    # Count how many function definitions with same name/arity exist
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, acc ->
        case node do
          {:def, _meta, [{^function_name, _call_meta, args}, _body]} when is_list(args) ->
            if length(args) == arity do
              {node, acc + 1}
            else
              {node, acc}
            end

          {:defp, _meta, [{^function_name, _call_meta, args}, _body]} when is_list(args) ->
            if length(args) == arity do
              {node, acc + 1}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)

    count > 1
  end

  defp extract_do_block(do: body), do: body
  defp extract_do_block(body), do: body

  # Apply inlining transformation
  defp apply_inlining(ast, function_info, remove_definition) do
    %{
      function_name: function_name,
      arity: arity,
      params: params,
      body: body
    } = function_info

    # Replace all calls to the function with inlined body
    transformed_ast =
      Macro.prewalk(ast, fn node ->
        case node do
          # Direct call: function_name(args...)
          {^function_name, _meta, args} when is_list(args) and length(args) == arity ->
            inline_call(body, params, args)

          # Qualified call: Module.function_name(args...)
          {{:., _dot_meta, [_module, ^function_name]}, _call_meta, args}
          when is_list(args) and length(args) == arity ->
            # For qualified calls, inline the body
            inline_call(body, params, args)

          _ ->
            node
        end
      end)

    # Remove function definition if requested
    final_ast =
      if remove_definition do
        remove_function_definition(transformed_ast, function_name, arity)
      else
        transformed_ast
      end

    {:ok, final_ast}
  end

  # Inline a function call by substituting parameters
  defp inline_call(body, params, args) do
    # Build substitution map
    substitutions =
      params
      |> Enum.zip(args)
      |> Map.new()

    # Substitute parameters in body
    substitute_vars(body, substitutions)
  end

  # Substitute variables in AST
  defp substitute_vars(ast, substitutions) do
    Macro.prewalk(ast, fn node ->
      case node do
        {var_name, _meta, context} when is_atom(var_name) and is_atom(context) ->
          # Check if this variable should be substituted
          case Map.get(substitutions, var_name) do
            nil -> node
            replacement -> replacement
          end

        _ ->
          node
      end
    end)
  end

  # Remove function definition from AST
  defp remove_function_definition(ast, function_name, arity) do
    Macro.prewalk(ast, fn node ->
      case node do
        # Remove from module body
        {:defmodule, meta,
         [{module_name, module_meta, module_ctx}, [do: {:__block__, block_meta, statements}]]} ->
          new_statements =
            Enum.reject(statements, fn stmt ->
              matches_function_def?(stmt, function_name, arity)
            end)

          {:defmodule, meta,
           [
             {module_name, module_meta, module_ctx},
             [do: {:__block__, block_meta, new_statements}]
           ]}

        # Single function module (no __block__)
        {:defmodule, meta, [{module_name, module_meta, module_ctx}, [do: single_stmt]]} ->
          if matches_function_def?(single_stmt, function_name, arity) do
            # Remove the only function, leave empty module
            {:defmodule, meta,
             [{module_name, module_meta, module_ctx}, [do: {:__block__, [], []}]]}
          else
            node
          end

        _ ->
          node
      end
    end)
  end

  @doc """
  Converts function visibility between public (def) and private (defp).

  ## Parameters
  - `content`: Source code as string
  - `module_name`: Module containing the function
  - `function_name`: Function to modify
  - `arity`: Function arity
  - `visibility`: :public or :private
  - `opts`: Options
    - `:add_doc` - Add documentation when making public (default: false)

  ## Returns
  - `{:ok, new_content}` on success
  - `{:error, reason}` on failure
  """
  @spec convert_visibility(
          String.t(),
          atom(),
          atom(),
          non_neg_integer(),
          :public | :private,
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def convert_visibility(
        content,
        _module_name,
        function_name,
        arity,
        visibility,
        opts \\ []
      ) do
    add_doc = Keyword.get(opts, :add_doc, false)

    with {:ok, ast} <- parse_code(content),
         transformed_ast <-
           apply_visibility_change(ast, function_name, arity, visibility, add_doc),
         {:ok, new_content} <- ast_to_string(transformed_ast) do
      {:ok, new_content}
    else
      {:error, _reason} = error -> error
    end
  end

  defp apply_visibility_change(ast, function_name, arity, visibility, add_doc) do
    target_def = if visibility == :public, do: :def, else: :defp

    Macro.prewalk(ast, fn node ->
      case node do
        # Convert def to defp
        {:def, meta, [{^function_name, call_meta, args}, body]} when is_list(args) ->
          if length(args) == arity do
            if target_def == :defp do
              {:defp, meta, [{function_name, call_meta, args}, body]}
            else
              node
            end
          else
            node
          end

        # Convert defp to def
        {:defp, meta, [{^function_name, call_meta, args}, body]} when is_list(args) ->
          if length(args) == arity do
            if target_def == :def do
              new_node = {:def, meta, [{function_name, call_meta, args}, body]}

              # Optionally add documentation
              if add_doc do
                doc_ast = {:@, [], [{:doc, [], ["TODO: Document this function"]}]}
                {:__block__, [], [doc_ast, new_node]}
              else
                new_node
              end
            else
              node
            end
          else
            node
          end

        # Also handle defmacro/defmacrop
        {:defmacro, meta, [{^function_name, call_meta, args}, body]} when is_list(args) ->
          if length(args) == arity do
            if target_def == :defp do
              {:defmacrop, meta, [{function_name, call_meta, args}, body]}
            else
              node
            end
          else
            node
          end

        {:defmacrop, meta, [{^function_name, call_meta, args}, body]} when is_list(args) ->
          if length(args) == arity do
            if target_def == :def do
              {:defmacro, meta, [{function_name, call_meta, args}, body]}
            else
              node
            end
          else
            node
          end

        _ ->
          node
      end
    end)
  end

  @doc """
  Renames a function parameter and all its references within the function body.

  ## Parameters
  - `content`: Source code as string
  - `module_name`: Module containing the function
  - `function_name`: Function to modify
  - `arity`: Function arity
  - `old_param_name`: Current parameter name
  - `new_param_name`: New parameter name
  - `opts`: Options (currently unused)

  ## Returns
  - `{:ok, new_content}` on success
  - `{:error, reason}` on failure
  """
  @spec rename_parameter(
          String.t(),
          atom(),
          atom(),
          non_neg_integer(),
          atom(),
          atom(),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def rename_parameter(
        content,
        _module_name,
        function_name,
        arity,
        old_param_name,
        new_param_name,
        _opts \\ []
      ) do
    with {:ok, ast} <- parse_code(content),
         transformed_ast <-
           apply_parameter_rename(ast, function_name, arity, old_param_name, new_param_name),
         {:ok, new_content} <- ast_to_string(transformed_ast) do
      {:ok, new_content}
    else
      {:error, _reason} = error -> error
    end
  end

  defp apply_parameter_rename(ast, function_name, arity, old_param, new_param) do
    Macro.prewalk(ast, fn node ->
      case node do
        # Match function definition
        {:def, meta, [{^function_name, call_meta, args}, body]} when is_list(args) ->
          if length(args) == arity do
            new_args = rename_in_params(args, old_param, new_param)
            new_body = rename_in_body(body, old_param, new_param)
            {:def, meta, [{function_name, call_meta, new_args}, new_body]}
          else
            node
          end

        {:defp, meta, [{^function_name, call_meta, args}, body]} when is_list(args) ->
          if length(args) == arity do
            new_args = rename_in_params(args, old_param, new_param)
            new_body = rename_in_body(body, old_param, new_param)
            {:defp, meta, [{function_name, call_meta, new_args}, new_body]}
          else
            node
          end

        _ ->
          node
      end
    end)
  end

  defp rename_in_params(params, old_name, new_name) do
    Enum.map(params, fn param ->
      case param do
        {^old_name, meta, context} -> {new_name, meta, context}
        _ -> param
      end
    end)
  end

  defp rename_in_body(body, old_name, new_name) do
    Macro.prewalk(body, fn node ->
      case node do
        {^old_name, meta, context} when is_atom(context) ->
          {new_name, meta, context}

        _ ->
          node
      end
    end)
  end

  @doc """
  Adds, removes, or updates module attributes.

  ## Parameters
  - `content`: Source code as string
  - `changes`: Map with :add, :remove, and/or :update keys
    - `:add` - List of {attribute_name, value} tuples to add
    - `:remove` - List of attribute names to remove
    - `:update` - List of {attribute_name, new_value} tuples to update
  - `opts`: Options (currently unused)

  ## Returns
  - `{:ok, new_content}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> changes = %{
      ...>   add: [{:vsn, "1.0.0"}],
      ...>   remove: [:deprecated],
      ...>   update: [{:moduledoc, "Updated documentation"}]
      ...> }
      iex> modify_attributes(content, changes)
      {:ok, updated_content}
  """
  @spec modify_attributes(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def modify_attributes(content, changes, _opts \\ []) do
    with {:ok, ast} <- parse_code(content),
         transformed_ast <- apply_attribute_changes(ast, changes),
         {:ok, new_content} <- ast_to_string(transformed_ast) do
      {:ok, new_content}
    else
      {:error, _reason} = error -> error
    end
  end

  defp apply_attribute_changes(ast, changes) do
    to_add = Map.get(changes, :add, [])
    to_remove = Map.get(changes, :remove, [])
    to_update = Map.get(changes, :update, [])

    Macro.prewalk(ast, fn node ->
      case node do
        # Module with block
        {:defmodule, meta,
         [{module_name, module_meta, module_ctx}, [do: {:__block__, block_meta, statements}]]} ->
          # Separate attributes from other statements
          {attributes, other_statements} =
            Enum.split_with(statements, fn stmt ->
              match?({:@, _, [{_attr_name, _, _}]}, stmt)
            end)

          # Apply changes
          modified_attributes =
            attributes
            |> remove_attributes(to_remove)
            |> update_attributes(to_update)

          # Add new attributes
          new_attributes =
            Enum.map(to_add, fn {attr_name, value} ->
              {:@, [], [{attr_name, [], [value]}]}
            end)

          # Combine: new attributes + modified attributes + other statements
          all_statements = new_attributes ++ modified_attributes ++ other_statements

          {:defmodule, meta,
           [
             {module_name, module_meta, module_ctx},
             [do: {:__block__, block_meta, all_statements}]
           ]}

        _ ->
          node
      end
    end)
  end

  defp remove_attributes(attributes, to_remove) do
    Enum.reject(attributes, fn
      {:@, _, [{attr_name, _, _}]} -> attr_name in to_remove
      _ -> false
    end)
  end

  defp update_attributes(attributes, to_update) do
    update_map = Map.new(to_update)

    Enum.map(attributes, fn
      {:@, meta, [{attr_name, attr_meta, _old_value}]} = attr ->
        case Map.get(update_map, attr_name) do
          nil -> attr
          new_value -> {:@, meta, [{attr_name, attr_meta, [new_value]}]}
        end

      other ->
        other
    end)
  end

  @doc """
  Changes a function signature by adding, removing, reordering, or renaming parameters.

  ## Parameters
  - `content`: Source code as string
  - `module_name`: Module containing the function
  - `function_name`: Function to modify
  - `old_arity`: Current function arity
  - `signature_changes`: Map describing the changes
  - `opts`: Options (currently unused)

  ## Signature Changes Format

  The `signature_changes` map can contain:
  - `:add_params` - List of params to add: `[%{name: atom, position: integer, default: any}]`
  - `:remove_params` - List of param positions to remove (0-indexed): `[0, 2]`
  - `:reorder_params` - New param order (0-indexed positions): `[2, 0, 1]`
  - `:rename_params` - List of renames: `[{old_name, new_name}]`

  ## Returns
  - `{:ok, new_content}` on success
  - `{:error, reason}` on failure

  ## Examples

      # Add a parameter with default value
      changes = %{add_params: [%{name: :opts, position: 2, default: []}]}
      change_signature(content, :MyModule, :process, 2, changes)

      # Remove second parameter (position 1)
      changes = %{remove_params: [1]}
      change_signature(content, :MyModule, :calculate, 3, changes)

      # Reorder parameters: swap first and second
      changes = %{reorder_params: [1, 0, 2]}
      change_signature(content, :MyModule, :transform, 3, changes)

      # Rename parameters
      changes = %{rename_params: [{:x, :input}, {:y, :output}]}
      change_signature(content, :MyModule, :convert, 2, changes)

      # Combine multiple operations
      changes = %{
        add_params: [%{name: :config, position: 0, default: %{}}],
        remove_params: [2],
        rename_params: [{:data, :payload}]
      }
      change_signature(content, :MyModule, :handler, 3, changes)
  """
  @spec change_signature(
          String.t(),
          atom(),
          atom(),
          non_neg_integer(),
          map(),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def change_signature(
        content,
        _module_name,
        function_name,
        old_arity,
        signature_changes,
        _opts \\ []
      ) do
    with {:ok, ast} <- parse_code(content),
         {:ok, function_info} <- extract_signature_info(ast, function_name, old_arity),
         {:ok, new_params, param_mapping} <-
           compute_new_signature(function_info.params, signature_changes),
         transformed_ast <-
           apply_signature_change(
             ast,
             function_name,
             old_arity,
             new_params,
             param_mapping,
             signature_changes
           ),
         {:ok, new_content} <- ast_to_string(transformed_ast) do
      {:ok, new_content}
    else
      {:error, _reason} = error -> error
    end
  end

  # Extract current function signature information
  defp extract_signature_info(ast, function_name, arity) do
    case find_function_definition(ast, function_name, arity) do
      nil ->
        {:error, "Function #{function_name}/#{arity} not found"}

      {_def_type, function_ast, _body} ->
        params = extract_function_params(function_ast)

        {:ok, %{params: params, arity: arity}}
    end
  end

  defp extract_function_params(function_ast) do
    case function_ast do
      {:def, _meta, [{_name, _call_meta, args}, _body]} when is_list(args) ->
        args

      {:defp, _meta, [{_name, _call_meta, args}, _body]} when is_list(args) ->
        args

      _ ->
        []
    end
  end

  # Compute new parameter list and mapping from old to new positions
  defp compute_new_signature(old_params, changes) do
    # Start with old parameters
    params_with_indices = Enum.with_index(old_params)

    # Step 1: Apply renames
    params_after_rename =
      case Map.get(changes, :rename_params) do
        nil ->
          params_with_indices

        renames ->
          rename_map = Map.new(renames)

          Enum.map(params_with_indices, fn {param, idx} ->
            new_param =
              case param do
                {name, meta, context} when is_atom(name) ->
                  case Map.get(rename_map, name) do
                    nil -> param
                    new_name -> {new_name, meta, context}
                  end

                _ ->
                  param
              end

            {new_param, idx}
          end)
      end

    # Step 2: Remove parameters
    params_after_remove =
      case Map.get(changes, :remove_params) do
        nil ->
          params_after_rename

        remove_positions ->
          remove_set = MapSet.new(remove_positions)

          Enum.reject(params_after_rename, fn {_param, idx} -> MapSet.member?(remove_set, idx) end)
      end

    # Step 3: Reorder parameters
    params_after_reorder =
      case Map.get(changes, :reorder_params) do
        nil ->
          params_after_remove

        new_order ->
          # Build lookup map
          param_map =
            params_after_remove
            |> Enum.map(fn {param, original_idx} -> {original_idx, param} end)
            |> Map.new()

          # Apply new order
          Enum.map(new_order, fn original_idx ->
            {Map.get(param_map, original_idx), original_idx}
          end)
      end

    # Step 4: Add new parameters
    params_after_add =
      case Map.get(changes, :add_params) do
        nil ->
          params_after_reorder

        params_to_add ->
          # Insert params at specified positions
          Enum.reduce(params_to_add, params_after_reorder, fn param_spec, acc ->
            %{name: name, position: pos} = param_spec
            # Note: default value is stored in param_spec but used later in update_call_args

            # Create parameter AST
            new_param = {name, [], nil}
            # Use negative index to mark as newly added
            new_entry = {new_param, -1}

            # Insert at position
            List.insert_at(acc, pos, new_entry)
          end)
      end

    # Build final parameter list and mapping
    final_params = Enum.map(params_after_add, fn {param, _idx} -> param end)

    # Build mapping: old_position -> new_position
    param_mapping =
      params_after_add
      |> Enum.with_index()
      |> Enum.map(fn {{_param, original_idx}, new_idx} -> {original_idx, new_idx} end)
      |> Enum.filter(fn {original_idx, _new_idx} -> original_idx >= 0 end)
      |> Map.new()

    {:ok, final_params, param_mapping}
  end

  # Apply signature changes to AST
  defp apply_signature_change(
         ast,
         function_name,
         old_arity,
         new_params,
         param_mapping,
         signature_changes
       ) do
    Macro.prewalk(ast, fn node ->
      case node do
        # Update function definition
        {:def, meta, [{^function_name, call_meta, args}, body]} when is_list(args) ->
          if length(args) == old_arity do
            # Update parameters in function head
            new_body = update_body_for_signature(body, signature_changes)
            {:def, meta, [{function_name, call_meta, new_params}, new_body]}
          else
            node
          end

        {:defp, meta, [{^function_name, call_meta, args}, body]} when is_list(args) ->
          if length(args) == old_arity do
            new_body = update_body_for_signature(body, signature_changes)
            {:defp, meta, [{function_name, call_meta, new_params}, new_body]}
          else
            node
          end

        # Update direct function calls
        {^function_name, meta, args} when is_list(args) ->
          if length(args) == old_arity do
            new_args = update_call_args(args, param_mapping, signature_changes)
            {function_name, meta, new_args}
          else
            node
          end

        # Update qualified function calls
        {{:., dot_meta, [module, ^function_name]}, call_meta, args} when is_list(args) ->
          if length(args) == old_arity do
            new_args = update_call_args(args, param_mapping, signature_changes)
            {{:., dot_meta, [module, function_name]}, call_meta, new_args}
          else
            node
          end

        _ ->
          node
      end
    end)
  end

  # Update function body to reflect parameter renames
  defp update_body_for_signature(body, signature_changes) do
    case Map.get(signature_changes, :rename_params) do
      nil ->
        body

      renames ->
        rename_map = Map.new(renames)
        rename_in_body_multi(body, rename_map)
    end
  end

  defp rename_in_body_multi(body, rename_map) do
    Macro.prewalk(body, fn node ->
      case node do
        {old_name, meta, context} when is_atom(old_name) and is_atom(context) ->
          case Map.get(rename_map, old_name) do
            nil -> node
            new_name -> {new_name, meta, context}
          end

        _ ->
          node
      end
    end)
  end

  # Update call arguments based on signature changes
  defp update_call_args(old_args, param_mapping, signature_changes) do
    # Step 1: Map old arguments to new positions
    reordered_args =
      old_args
      |> Enum.with_index()
      |> Enum.map(fn {arg, old_idx} ->
        new_idx = Map.get(param_mapping, old_idx)
        {arg, old_idx, new_idx}
      end)
      |> Enum.reject(fn {_arg, _old_idx, new_idx} -> is_nil(new_idx) end)
      |> Enum.sort_by(fn {_arg, _old_idx, new_idx} -> new_idx end)
      |> Enum.map(fn {arg, _old_idx, _new_idx} -> arg end)

    # Step 2: Add default values for new parameters
    final_args =
      case Map.get(signature_changes, :add_params) do
        nil ->
          reordered_args

        params_to_add ->
          # Insert defaults at specified positions
          Enum.reduce(params_to_add, reordered_args, fn param_spec, acc ->
            %{position: pos} = param_spec
            default = Map.get(param_spec, :default)

            # Create default value AST
            default_ast =
              case default do
                nil -> nil
                val when is_atom(val) -> val
                val when is_number(val) -> val
                val when is_binary(val) -> val
                val when is_list(val) -> val
                val when is_map(val) -> {:%{}, [], Map.to_list(val)}
                _ -> nil
              end

            if default_ast do
              List.insert_at(acc, pos, default_ast)
            else
              # No default provided, use nil
              List.insert_at(acc, pos, nil)
            end
          end)
      end

    final_args
  end

  @doc """
  Moves a function from one module to another.

  ## Parameters
  - `source_content`: Source module code
  - `target_content`: Target module code (or nil for new module)
  - `source_module`: Source module name
  - `target_module`: Target module name
  - `function_name`: Function to move
  - `arity`: Function arity
  - `opts`: Options
    - `:placement` - :start | :end (default: :end)
    - `:update_references` - boolean (default: true)

  ## Returns
  - `{:ok, %{source: new_source, target: new_target}}` on success
  - `{:error, reason}` on failure
  """
  @spec move_function(
          String.t(),
          String.t() | nil,
          atom(),
          atom(),
          atom(),
          non_neg_integer(),
          keyword()
        ) :: {:ok, %{source: String.t(), target: String.t()}} | {:error, term()}
  def move_function(
        source_content,
        target_content,
        source_module,
        target_module,
        function_name,
        arity,
        opts \\ []
      ) do
    placement = Keyword.get(opts, :placement, :end)
    update_references = Keyword.get(opts, :update_references, true)

    with {:ok, source_ast} <- parse_code(source_content),
         {:ok, function_def} <- extract_function_definition_ast(source_ast, function_name, arity),
         {:ok, new_source_ast} <- remove_function_from_ast(source_ast, function_name, arity),
         {:ok, new_source_content} <- ast_to_string(new_source_ast),
         {:ok, new_target_content} <-
           add_function_to_module(
             target_content,
             target_module,
             function_def,
             placement
           ),
         {:ok, final_source} <-
           maybe_update_references(
             new_source_content,
             function_name,
             source_module,
             target_module,
             update_references
           ),
         {:ok, final_target} <-
           maybe_update_references(
             new_target_content,
             function_name,
             source_module,
             target_module,
             update_references
           ) do
      {:ok, %{source: final_source, target: final_target}}
    else
      {:error, _reason} = error -> error
    end
  end

  # Extract function definition as AST
  defp extract_function_definition_ast(ast, function_name, arity) do
    result =
      Macro.prewalk(ast, nil, fn node, acc ->
        case acc do
          nil ->
            case node do
              {:def, _meta, [{^function_name, _call_meta, args}, _body]} = func
              when is_list(args) ->
                if length(args) == arity do
                  {node, func}
                else
                  {node, nil}
                end

              {:defp, _meta, [{^function_name, _call_meta, args}, _body]} = func
              when is_list(args) ->
                if length(args) == arity do
                  {node, func}
                else
                  {node, nil}
                end

              _ ->
                {node, nil}
            end

          found ->
            {node, found}
        end
      end)

    case result do
      {_ast, nil} -> {:error, "Function #{function_name}/#{arity} not found"}
      {_ast, function_def} -> {:ok, function_def}
    end
  end

  # Remove function from AST
  defp remove_function_from_ast(ast, function_name, arity) do
    new_ast = remove_function_definition(ast, function_name, arity)
    {:ok, new_ast}
  end

  # Add function to target module
  defp add_function_to_module(nil, target_module, function_def, _placement) do
    # Create new module with the function
    module_ast =
      {:defmodule, [],
       [
         {:__aliases__, [], [target_module]},
         [do: {:__block__, [], [function_def]}]
       ]}

    ast_to_string(module_ast)
  end

  defp add_function_to_module(target_content, _target_module, function_def, placement) do
    with {:ok, target_ast} <- parse_code(target_content) do
      new_ast =
        case placement do
          :start -> insert_function_at_start(target_ast, function_def)
          :end -> insert_at_module_end(target_ast, function_def)
        end

      ast_to_string(new_ast)
    end
  end

  defp insert_function_at_start(ast, function_def) do
    Macro.prewalk(ast, fn node ->
      case node do
        {:defmodule, meta,
         [{module_name, module_meta, module_ctx}, [do: {:__block__, block_meta, statements}]]} ->
          # Find first function and insert before it
          {before_first_func, from_first_func} =
            Enum.split_while(statements, fn stmt ->
              not match?(
                {def_type, _, _} when def_type in [:def, :defp, :defmacro, :defmacrop],
                stmt
              )
            end)

          new_statements = before_first_func ++ [function_def | from_first_func]

          {:defmodule, meta,
           [
             {module_name, module_meta, module_ctx},
             [do: {:__block__, block_meta, new_statements}]
           ]}

        _ ->
          node
      end
    end)
  end

  @doc """
  Extracts multiple functions from a module into a new module.

  ## Parameters
  - `source_content`: Source module code
  - `source_module`: Source module name
  - `new_module`: New module name
  - `functions`: List of {function_name, arity} tuples to extract
  - `opts`: Options
    - `:add_moduledoc` - boolean (default: true)
    - `:update_aliases` - boolean (default: true)

  ## Returns
  - `{:ok, %{source: new_source, target: new_module_content}}` on success
  - `{:error, reason}` on failure

  ## Examples

      functions = [{:helper, 1}, {:process, 2}]
      extract_module(content, :MyModule, :MyModule.Helpers, functions)
  """
  @spec extract_module(
          String.t(),
          atom(),
          atom(),
          [{atom(), non_neg_integer()}],
          keyword()
        ) :: {:ok, %{source: String.t(), target: String.t()}} | {:error, term()}
  def extract_module(source_content, source_module, new_module, functions, opts \\ []) do
    add_moduledoc = Keyword.get(opts, :add_moduledoc, true)
    update_aliases = Keyword.get(opts, :update_aliases, true)

    with {:ok, source_ast} <- parse_code(source_content),
         {:ok, function_defs} <- extract_multiple_functions(source_ast, functions),
         {:ok, new_source_ast} <- remove_multiple_functions(source_ast, functions),
         {:ok, new_source_content} <- ast_to_string(new_source_ast),
         {:ok, new_module_content} <-
           create_new_module(new_module, function_defs, add_moduledoc),
         {:ok, final_source} <-
           maybe_add_alias(new_source_content, new_module, update_aliases),
         {:ok, final_source_with_refs} <-
           update_function_references(final_source, source_module, new_module, functions) do
      {:ok, %{source: final_source_with_refs, target: new_module_content}}
    else
      {:error, _reason} = error -> error
    end
  end

  # Extract multiple function definitions
  defp extract_multiple_functions(ast, functions) do
    results =
      Enum.map(functions, fn {func_name, arity} ->
        extract_function_definition_ast(ast, func_name, arity)
      end)

    # Check if all succeeded
    errors = Enum.filter(results, fn result -> match?({:error, _}, result) end)

    if Enum.empty?(errors) do
      function_defs = Enum.map(results, fn {:ok, def_ast} -> def_ast end)
      {:ok, function_defs}
    else
      {:error, "Failed to extract some functions: #{inspect(errors)}"}
    end
  end

  # Remove multiple functions from AST
  defp remove_multiple_functions(ast, functions) do
    new_ast =
      Enum.reduce(functions, ast, fn {func_name, arity}, acc_ast ->
        remove_function_definition(acc_ast, func_name, arity)
      end)

    {:ok, new_ast}
  end

  # Create new module with extracted functions
  defp create_new_module(module_name, function_defs, add_moduledoc) do
    # Build module body
    body_statements =
      if add_moduledoc do
        moduledoc = {:@, [], [{:moduledoc, [], ["Extracted functions from parent module."]}]}
        [moduledoc | function_defs]
      else
        function_defs
      end

    # Build module AST
    module_ast =
      {:defmodule, [],
       [
         {:__aliases__, [], split_module_name(module_name)},
         [do: {:__block__, [], body_statements}]
       ]}

    ast_to_string(module_ast)
  end

  # Add alias to source module
  defp maybe_add_alias(content, _new_module, false), do: {:ok, content}

  defp maybe_add_alias(content, new_module, true) do
    with {:ok, ast} <- parse_code(content) do
      # Add alias after module definition
      new_ast =
        Macro.prewalk(ast, fn node ->
          case node do
            {:defmodule, meta,
             [{module_name, module_meta, module_ctx}, [do: {:__block__, block_meta, statements}]]} ->
              # Find where to insert alias (after other module attributes, before first function)
              {attrs, rest} =
                Enum.split_while(statements, fn stmt ->
                  match?({:@, _, _}, stmt) or match?({:alias, _, _}, stmt) or
                    match?({:import, _, _}, stmt) or match?({:require, _, _}, stmt)
                end)

              # Build alias statement
              alias_ast = {:alias, [], [{:__aliases__, [], split_module_name(new_module)}]}

              new_statements = attrs ++ [alias_ast | rest]

              {:defmodule, meta,
               [
                 {module_name, module_meta, module_ctx},
                 [do: {:__block__, block_meta, new_statements}]
               ]}

            _ ->
              node
          end
        end)

      ast_to_string(new_ast)
    end
  end

  # Update function references to use new module
  defp update_function_references(content, source_module, new_module, functions) do
    function_names = MapSet.new(functions, fn {name, _arity} -> name end)

    with {:ok, ast} <- parse_code(content) do
      new_ast =
        Macro.prewalk(ast, fn node ->
          case node do
            # Unqualified call - add module qualifier for extracted functions
            {func_name, _meta, args} when is_list(args) ->
              if MapSet.member?(function_names, func_name) do
                # Convert to qualified call
                new_module_alias = List.last(split_module_name(new_module))
                {{:., [], [{:__aliases__, [], [new_module_alias]}, func_name]}, [], args}
              else
                node
              end

            # Qualified call with source module
            {{:., dot_meta, [{:__aliases__, alias_meta, [^source_module]}, func_name]}, call_meta,
             args} ->
              if MapSet.member?(function_names, func_name) do
                # Change to new module
                new_module_alias = List.last(split_module_name(new_module))

                {{:., dot_meta, [{:__aliases__, alias_meta, [new_module_alias]}, func_name]},
                 call_meta, args}
              else
                node
              end

            _ ->
              node
          end
        end)

      ast_to_string(new_ast)
    end
  end

  # Update references to use new module
  defp maybe_update_references(content, _function_name, _source_module, _target_module, false) do
    {:ok, content}
  end

  defp maybe_update_references(content, function_name, source_module, target_module, true) do
    with {:ok, ast} <- parse_code(content) do
      # Update calls from SourceModule.function to TargetModule.function
      new_ast =
        Macro.prewalk(ast, fn node ->
          case node do
            # Qualified call with source module
            {{:., dot_meta, [{:__aliases__, alias_meta, [^source_module]}, ^function_name]},
             call_meta, args} ->
              # Change to target module
              {{:., dot_meta, [{:__aliases__, alias_meta, [target_module]}, function_name]},
               call_meta, args}

            _ ->
              node
          end
        end)

      ast_to_string(new_ast)
    end
  end

  # Collect line numbers of function calls
  defp collect_call_lines(ast, function_name, target_arity) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          # Function call: function_name(...)
          {^function_name, meta, args} when is_list(args) ->
            if target_arity == nil or length(args) == target_arity do
              line = Keyword.get(meta, :line, 0)
              {node, [line | acc]}
            else
              {node, acc}
            end

          # Module-qualified call: Module.function_name(...)
          {{:., _dot_meta, [_module, ^function_name]}, meta, args} when is_list(args) ->
            if target_arity == nil or length(args) == target_arity do
              line = Keyword.get(meta, :line, 0)
              {node, [line | acc]}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)

    Enum.reverse(lines)
  end
end
