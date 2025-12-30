defmodule Ragex.Analyzers.Erlang do
  @moduledoc """
  Analyzes Erlang code to extract modules, functions, calls, and dependencies.

  Uses :erl_scan and :erl_parse from the Erlang standard library to parse
  the code into an abstract syntax tree.
  """

  @behaviour Ragex.Analyzers.Behaviour

  @impl true
  def analyze(source, file_path) do
    case scan_and_parse(source) do
      {:ok, forms} ->
        context = %{
          file: file_path,
          current_module: nil,
          modules: [],
          functions: [],
          calls: [],
          imports: []
        }

        context = analyze_forms(forms, context)

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
  def supported_extensions, do: [".erl", ".hrl"]

  # Private functions

  defp scan_and_parse(source) do
    source_charlist = String.to_charlist(source)

    case :erl_scan.string(source_charlist) do
      {:ok, tokens, _} ->
        parse_forms(tokens, [])

      {:error, error_info, _} ->
        {:error, {:scan_error, error_info}}
    end
  end

  defp parse_forms([], forms), do: {:ok, Enum.reverse(forms)}

  defp parse_forms([{:dot, _} | _rest] = tokens, forms) when tokens == [] do
    {:ok, Enum.reverse(forms)}
  end

  defp parse_forms(tokens, forms) do
    # Find the next dot token to get one complete form
    case find_form_tokens(tokens, []) do
      {form_tokens, remaining_tokens} when form_tokens != [] ->
        case :erl_parse.parse_form(form_tokens) do
          {:ok, form} ->
            parse_forms(remaining_tokens, [form | forms])

          {:error, _reason} ->
            # Skip this form and continue
            parse_forms(remaining_tokens, forms)
        end

      {[], []} ->
        {:ok, Enum.reverse(forms)}
    end
  end

  # Find tokens for one complete form (up to and including the dot)
  defp find_form_tokens([], acc), do: {Enum.reverse(acc), []}

  defp find_form_tokens([{:dot, _line} = dot | rest], acc) do
    {Enum.reverse([dot | acc]), rest}
  end

  defp find_form_tokens([token | rest], acc) do
    find_form_tokens(rest, [token | acc])
  end

  defp analyze_forms(forms, context) do
    Enum.reduce(forms, context, &analyze_form/2)
  end

  # Module attribute
  defp analyze_form({:attribute, line, :module, module_name}, context) do
    module_info = %{
      name: module_name,
      file: context.file,
      line: line,
      doc: nil,
      metadata: %{}
    }

    %{context | current_module: module_name, modules: [module_info | context.modules]}
  end

  # Import attribute
  defp analyze_form({:attribute, _line, :import, {module_name, _functions}}, context) do
    if context.current_module do
      import_info = %{
        from_module: context.current_module,
        to_module: module_name,
        type: :import
      }

      %{context | imports: [import_info | context.imports]}
    else
      context
    end
  end

  # Function definition
  defp analyze_form({:function, line, name, arity, clauses}, context) do
    if context.current_module do
      func_info = %{
        name: name,
        arity: arity,
        module: context.current_module,
        file: context.file,
        line: line,
        doc: nil,
        visibility: if(is_exported?(name, arity, context), do: :public, else: :private),
        metadata: %{}
      }

      context = %{context | functions: [func_info | context.functions]}

      # Extract calls from function clauses
      Enum.reduce(clauses, context, fn clause, ctx ->
        extract_calls_from_clause(clause, name, arity, ctx)
      end)
    else
      context
    end
  end

  # Export attribute (store for determining visibility)
  defp analyze_form({:attribute, _line, :export, functions}, context) do
    exported = Map.get(context, :exported, MapSet.new())

    exported =
      Enum.reduce(functions, exported, fn {name, arity}, acc ->
        MapSet.put(acc, {name, arity})
      end)

    Map.put(context, :exported, exported)
  end

  # Other forms
  defp analyze_form(_form, context), do: context

  defp is_exported?(name, arity, context) do
    exported = Map.get(context, :exported, MapSet.new())
    MapSet.member?(exported, {name, arity})
  end

  defp extract_calls_from_clause(
         {:clause, _line, _patterns, _guards, body},
         from_func,
         from_arity,
         context
       ) do
    extract_calls_from_body(body, from_func, from_arity, context)
  end

  defp extract_calls_from_body(body, from_func, from_arity, context) when is_list(body) do
    Enum.reduce(body, context, fn expr, ctx ->
      extract_calls_from_expr(expr, from_func, from_arity, ctx)
    end)
  end

  defp extract_calls_from_body(expr, from_func, from_arity, context) do
    extract_calls_from_expr(expr, from_func, from_arity, context)
  end

  # Remote call: module:function(args)
  defp extract_calls_from_expr(
         {:call, line, {:remote, _, {:atom, _, module}, {:atom, _, function}}, args},
         from_func,
         from_arity,
         context
       ) do
    call_info = %{
      from_module: context.current_module,
      from_function: from_func,
      from_arity: from_arity,
      to_module: module,
      to_function: function,
      to_arity: length(args),
      line: line
    }

    context = %{context | calls: [call_info | context.calls]}

    # Recursively extract calls from arguments
    Enum.reduce(args, context, fn arg, ctx ->
      extract_calls_from_expr(arg, from_func, from_arity, ctx)
    end)
  end

  # Local call: function(args)
  defp extract_calls_from_expr(
         {:call, line, {:atom, _, function}, args},
         from_func,
         from_arity,
         context
       ) do
    call_info = %{
      from_module: context.current_module,
      from_function: from_func,
      from_arity: from_arity,
      to_module: context.current_module,
      to_function: function,
      to_arity: length(args),
      line: line
    }

    context = %{context | calls: [call_info | context.calls]}

    # Recursively extract calls from arguments
    Enum.reduce(args, context, fn arg, ctx ->
      extract_calls_from_expr(arg, from_func, from_arity, ctx)
    end)
  end

  # Tuple
  defp extract_calls_from_expr({:tuple, _line, elements}, from_func, from_arity, context) do
    Enum.reduce(elements, context, fn elem, ctx ->
      extract_calls_from_expr(elem, from_func, from_arity, ctx)
    end)
  end

  # List
  defp extract_calls_from_expr({:cons, _line, head, tail}, from_func, from_arity, context) do
    context = extract_calls_from_expr(head, from_func, from_arity, context)
    extract_calls_from_expr(tail, from_func, from_arity, context)
  end

  # Case expression
  defp extract_calls_from_expr({:case, _line, expr, clauses}, from_func, from_arity, context) do
    context = extract_calls_from_expr(expr, from_func, from_arity, context)

    Enum.reduce(clauses, context, fn clause, ctx ->
      extract_calls_from_clause(clause, from_func, from_arity, ctx)
    end)
  end

  # If expression
  defp extract_calls_from_expr({:if, _line, clauses}, from_func, from_arity, context) do
    Enum.reduce(clauses, context, fn clause, ctx ->
      extract_calls_from_clause(clause, from_func, from_arity, ctx)
    end)
  end

  # Match expression
  defp extract_calls_from_expr({:match, _line, _pattern, expr}, from_func, from_arity, context) do
    extract_calls_from_expr(expr, from_func, from_arity, context)
  end

  # Binary operation
  defp extract_calls_from_expr({:op, _line, _op, left, right}, from_func, from_arity, context) do
    context = extract_calls_from_expr(left, from_func, from_arity, context)
    extract_calls_from_expr(right, from_func, from_arity, context)
  end

  # Unary operation
  defp extract_calls_from_expr({:op, _line, _op, expr}, from_func, from_arity, context) do
    extract_calls_from_expr(expr, from_func, from_arity, context)
  end

  # Atoms, numbers, variables, etc. - no calls
  defp extract_calls_from_expr(_other, _from_func, _from_arity, context), do: context
end
