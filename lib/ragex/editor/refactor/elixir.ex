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
    try do
      # Use Macro.to_string for basic conversion
      code = Macro.to_string(ast)
      {:ok, code}
    rescue
      e ->
        {:error, "Failed to convert AST to string: #{inspect(e)}"}
    end
  end

  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value) when is_binary(value), do: String.to_atom(value)

  # Transform function definitions and calls
  defp transform_function_names(ast, old_name, new_name, target_arity) do
    Macro.prewalk(ast, fn node ->
      case node do
        # Function definition: def old_name(...) or defp old_name(...)
        {:def, meta, [{^old_name, call_meta, args} = _call, body]} when is_list(args) ->
          if target_arity == nil or length(args) == target_arity do
            {:def, meta, [{new_name, call_meta, args}, body]}
          else
            node
          end

        {:defp, meta, [{^old_name, call_meta, args} = _call, body]} when is_list(args) ->
          if target_arity == nil or length(args) == target_arity do
            {:defp, meta, [{new_name, call_meta, args}, body]}
          else
            node
          end

        # Function call: old_name(...)
        {^old_name, meta, args} when is_list(args) ->
          if target_arity == nil or length(args) == target_arity do
            {new_name, meta, args}
          else
            node
          end

        # Module-qualified call: Module.old_name(...)
        {{:., dot_meta, [module, ^old_name]}, call_meta, args} when is_list(args) ->
          if target_arity == nil or length(args) == target_arity do
            {{:., dot_meta, [module, new_name]}, call_meta, args}
          else
            node
          end

        # Function reference: &old_name/arity
        {:&, meta, [{:/, slash_meta, [{^old_name, name_meta, context}, arity]}]}
        when is_integer(arity) ->
          if target_arity == nil or arity == target_arity do
            {:&, meta, [{:/, slash_meta, [{new_name, name_meta, context}, arity]}]}
          else
            node
          end

        _ ->
          node
      end
    end)
  end

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
