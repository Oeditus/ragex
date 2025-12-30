defmodule Ragex.Analyzers.JavaScript do
  @moduledoc """
  Analyzes JavaScript code to extract modules, functions, calls, and dependencies.

  Uses regex-based parsing for basic JavaScript/TypeScript patterns.
  This is a simplified analyzer that works for common cases.
  """

  @behaviour Ragex.Analyzers.Behaviour

  @impl true
  def analyze(source, file_path) do
    module_name = Path.basename(file_path, Path.extname(file_path)) |> String.to_atom()

    context = %{
      file: file_path,
      module_name: module_name,
      modules: [],
      functions: [],
      calls: [],
      imports: []
    }

    lines = String.split(source, "\n")
    context = analyze_lines(lines, context, 1)

    # Add file-level module
    context = add_file_module(context)

    result = %{
      modules: Enum.reverse(context.modules),
      functions: Enum.reverse(context.functions),
      calls: Enum.reverse(context.calls),
      imports: Enum.reverse(context.imports)
    }

    {:ok, result}
  rescue
    e -> {:error, {:analysis_error, Exception.message(e)}}
  end

  @impl true
  def supported_extensions, do: [".js", ".jsx", ".ts", ".tsx", ".mjs"]

  # Private functions

  defp analyze_lines([], context, _line_num), do: context

  defp analyze_lines([line | rest], context, line_num) do
    context =
      context
      |> extract_imports(line, line_num)
      |> extract_class(line, line_num)
      |> extract_functions(line, line_num)
      |> extract_calls(line, line_num)

    analyze_lines(rest, context, line_num + 1)
  end

  defp add_file_module(context) do
    module_info = %{
      name: context.module_name,
      file: context.file,
      line: 1,
      doc: nil,
      metadata: %{type: :file}
    }

    %{context | modules: [module_info | context.modules]}
  end

  # Extract ES6 imports and require statements
  defp extract_imports(context, line, _line_num) do
    cond do
      # import ... from '...'
      Regex.match?(~r/^\s*import\s+.*\s+from\s+['"](.+)['"]/, line) ->
        case Regex.run(~r/^\s*import\s+.*\s+from\s+['"](.+)['"]/, line) do
          [_, module] ->
            import_info = %{
              from_module: context.module_name,
              to_module: sanitize_module_name(module),
              type: :import
            }

            %{context | imports: [import_info | context.imports]}

          _ ->
            context
        end

      # const ... = require('...')
      Regex.match?(~r/require\s*\(\s*['"](.+)['"]\s*\)/, line) ->
        case Regex.run(~r/require\s*\(\s*['"](.+)['"]\s*\)/, line) do
          [_, module] ->
            import_info = %{
              from_module: context.module_name,
              to_module: sanitize_module_name(module),
              type: :require
            }

            %{context | imports: [import_info | context.imports]}

          _ ->
            context
        end

      true ->
        context
    end
  end

  # Extract class declarations
  defp extract_class(context, line, line_num) do
    case Regex.run(~r/^\s*(?:export\s+)?class\s+(\w+)/, line) do
      [_, class_name] ->
        module_info = %{
          name: String.to_atom(class_name),
          file: context.file,
          line: line_num,
          doc: nil,
          metadata: %{type: :class}
        }

        %{context | modules: [module_info | context.modules]}

      _ ->
        context
    end
  end

  # Extract function declarations
  defp extract_functions(context, line, line_num) do
    cond do
      # function name(...) {}
      Regex.match?(~r/^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\(([^)]*)\)/, line) ->
        case Regex.run(~r/^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\(([^)]*)\)/, line) do
          [_, func_name, params] ->
            arity = count_params(params)

            func_info = %{
              name: String.to_atom(func_name),
              arity: arity,
              module: context.module_name,
              file: context.file,
              line: line_num,
              doc: nil,
              visibility: if(String.starts_with?(func_name, "_"), do: :private, else: :public),
              metadata: %{}
            }

            %{context | functions: [func_info | context.functions]}

          _ ->
            context
        end

      # const name = (...) => {}
      # let name = (...) => {}
      # var name = (...) => {}
      # Handles: const add = (a: number, b: number): number => ...
      Regex.match?(
        ~r/^\s*(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?\([^)]*\)(?::[^=]+)?\s*=>/,
        line
      ) ->
        case Regex.run(
               ~r/^\s*(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?\(([^)]*)\)(?::[^=]+)?\s*=>/,
               line
             ) do
          [_, func_name, params] ->
            arity = count_params(params)

            func_info = %{
              name: String.to_atom(func_name),
              arity: arity,
              module: context.module_name,
              file: context.file,
              line: line_num,
              doc: nil,
              visibility: if(String.starts_with?(func_name, "_"), do: :private, else: :public),
              metadata: %{arrow_function: true}
            }

            %{context | functions: [func_info | context.functions]}

          _ ->
            context
        end

      # Method in class: methodName(...) {}
      Regex.match?(~r/^\s*(?:async\s+)?(\w+)\s*\(([^)]*)\)\s*\{/, line) and
          not Regex.match?(~r/^\s*(?:if|for|while|switch|catch)\s*\(/, line) ->
        case Regex.run(~r/^\s*(?:async\s+)?(\w+)\s*\(([^)]*)\)\s*\{/, line) do
          [_, func_name, params] ->
            arity = count_params(params)

            func_info = %{
              name: String.to_atom(func_name),
              arity: arity,
              module: context.module_name,
              file: context.file,
              line: line_num,
              doc: nil,
              visibility: if(String.starts_with?(func_name, "_"), do: :private, else: :public),
              metadata: %{}
            }

            %{context | functions: [func_info | context.functions]}

          _ ->
            context
        end

      true ->
        context
    end
  end

  # Extract function calls
  defp extract_calls(context, line, line_num) do
    # Match patterns like: functionName(...) or object.method(...)
    regex = ~r/(\w+)(?:\.(\w+))?\s*\(/

    Regex.scan(regex, line)
    |> Enum.reduce(context, fn match, ctx ->
      case match do
        [_, obj, method] when method != "" ->
          call_info = %{
            from_module: ctx.module_name,
            from_function: :unknown,
            from_arity: 0,
            to_module: String.to_atom(obj),
            to_function: String.to_atom(method),
            to_arity: 0,
            line: line_num
          }

          %{ctx | calls: [call_info | ctx.calls]}

        [_, func] ->
          # Skip common control flow keywords
          if func not in ["if", "for", "while", "switch", "catch", "return"] do
            call_info = %{
              from_module: ctx.module_name,
              from_function: :unknown,
              from_arity: 0,
              to_module: ctx.module_name,
              to_function: String.to_atom(func),
              to_arity: 0,
              line: line_num
            }

            %{ctx | calls: [call_info | ctx.calls]}
          else
            ctx
          end

        _ ->
          ctx
      end
    end)
  end

  defp count_params(""), do: 0

  defp count_params(params) do
    params
    |> String.trim()
    |> String.split(",")
    |> Enum.count()
  end

  defp sanitize_module_name(module) do
    module
    |> String.replace(~r/^[@.\/]+/, "")
    |> String.replace("/", ".")
    |> String.to_atom()
  end
end
