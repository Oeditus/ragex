defmodule Ragex.Analysis.ASTLocationExtractor do
  @moduledoc """
  Extracts location information from language-specific ASTs before MetaAST transformation.

  ## Purpose

  Phase 1 of comprehensive location solution: Extract line/column information from
  native AST representations before Metastatic abstracts them into MetaAST.

  This module provides language-specific extractors that traverse the original AST
  and build a location map that can be correlated with analysis results.

  ## Supported Languages

  - **Elixir**: Extracts from `{:atom, metadata, args}` tuples
  - **Erlang**: Extracts from erl_parse metadata
  - **Python**: Extracts from ast.AST node attributes (via Metastatic adapter)
  - **Ruby/Haskell**: Planned

  ## Usage

      alias Ragex.Analysis.ASTLocationExtractor

      # Extract from Elixir code
      {:ok, ast} = Code.string_to_quoted(source)
      location_map = ASTLocationExtractor.extract_elixir(ast)

      # Extract from file content (auto-detect language)
      {:ok, location_map} = ASTLocationExtractor.extract_from_file(path)

  ## Location Map Structure

  The location map stores node identifiers mapped to location information:

      %{
        "Module.function/2" => %{line: 42, column: 5},
        "SomeModule" => %{line: 10, column: 1}
      }
  """

  require Logger

  @type location :: %{
          line: non_neg_integer(),
          column: non_neg_integer() | nil,
          end_line: non_neg_integer() | nil,
          end_column: non_neg_integer() | nil
        }

  @type location_map :: %{String.t() => location()}

  @doc """
  Extracts location information from a file.

  Auto-detects language and uses appropriate extractor.

  ## Parameters
  - `path` - File path
  - `opts` - Keyword options
    - `:language` - Override language detection

  ## Returns
  - `{:ok, location_map}` - Map of identifiers to locations
  - `{:error, reason}` - Extraction failed
  """
  @spec extract_from_file(String.t(), keyword()) :: {:ok, location_map()} | {:error, term()}
  def extract_from_file(path, opts \\ []) do
    language = Keyword.get(opts, :language, detect_language(path))

    case File.read(path) do
      {:ok, content} ->
        extract_from_content(content, language)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extracts location information from source code content.

  ## Parameters
  - `content` - Source code string
  - `language` - Language atom (`:elixir`, `:erlang`, `:python`, etc.)

  ## Returns
  - `{:ok, location_map}` - Map of identifiers to locations
  - `{:error, reason}` - Extraction failed
  """
  @spec extract_from_content(String.t(), atom()) :: {:ok, location_map()} | {:error, term()}
  def extract_from_content(content, :elixir) do
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        {:ok, extract_elixir(ast)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def extract_from_content(content, :erlang) do
    extract_erlang(content)
  end

  def extract_from_content(_content, :python) do
    # Python AST extraction would require calling Python interpreter
    # For now, return empty map - Metastatic adapter handles this
    {:ok, %{}}
  end

  def extract_from_content(_content, language) do
    Logger.debug("Location extraction not implemented for #{language}")
    {:ok, %{}}
  end

  @doc """
  Extracts location information from Elixir AST.

  Traverses the Elixir AST tuple structure and extracts line/column from metadata.

  ## Examples

      iex> ast = quote do
      ...>   defmodule MyModule do
      ...>     def hello(name), do: "Hello \#{name}"
      ...>   end
      ...> end
      iex> locations = ASTLocationExtractor.extract_elixir(ast)
      iex> is_map(locations)
      true
  """
  @spec extract_elixir(Macro.t()) :: location_map()
  def extract_elixir(ast) do
    # Build location map by traversing AST
    locations = %{}

    locations
    |> extract_elixir_node(ast, [])
    |> elem(0)
  end

  # Private functions for Elixir extraction

  defp extract_elixir_node(locations, {:defmodule, meta, [module_alias, [do: body]]}, context) do
    # Extract module name
    module_name = extract_module_name(module_alias)
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    locations =
      if line do
        Map.put(locations, module_name, build_location(line, column))
      else
        locations
      end

    # Traverse module body
    new_context = [module_name | context]
    extract_elixir_node(locations, body, new_context)
  end

  defp extract_elixir_node(locations, {:def, meta, [signature, [do: _body]]} = _node, context) do
    {name, arity} = extract_function_signature(signature)
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    updated_locations =
      if name && arity && line do
        module_name = context |> Enum.reverse() |> Enum.join(".")
        func_key = "#{module_name}.#{name}/#{arity}"
        Map.put(locations, func_key, build_location(line, column))
      else
        locations
      end

    {updated_locations, context}
  end

  defp extract_elixir_node(locations, {:defp, meta, [signature, [do: _body]]}, context) do
    {name, arity} = extract_function_signature(signature)
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    updated_locations =
      if name && arity && line do
        module_name = context |> Enum.reverse() |> Enum.join(".")
        func_key = "#{module_name}.#{name}/#{arity}"
        Map.put(locations, func_key, build_location(line, column))
      else
        locations
      end

    {updated_locations, context}
  end

  defp extract_elixir_node(locations, {form, _meta, args}, context)
       when form in [:__block__, :do, :fn, :case, :cond, :with, :for, :if, :unless] and
              is_list(args) do
    # Traverse block/control flow structures
    Enum.reduce(args, locations, fn arg, acc ->
      extract_elixir_node(acc, arg, context) |> elem(0)
    end)
    |> then(&{&1, context})
  end

  defp extract_elixir_node(locations, list, context) when is_list(list) do
    # Traverse lists
    Enum.reduce(list, locations, fn item, acc ->
      extract_elixir_node(acc, item, context) |> elem(0)
    end)
    |> then(&{&1, context})
  end

  defp extract_elixir_node(locations, {left, right}, context) do
    # Traverse tuples
    {locations, _} = extract_elixir_node(locations, left, context)
    extract_elixir_node(locations, right, context)
  end

  defp extract_elixir_node(locations, _other, context) do
    # Base case: atoms, numbers, strings, etc.
    {locations, context}
  end

  defp extract_module_name({:__aliases__, _meta, parts}) do
    Enum.map_join(parts, ".", &to_string/1)
  end

  defp extract_module_name(atom) when is_atom(atom) do
    Atom.to_string(atom)
  end

  defp extract_module_name(_), do: "UnknownModule"

  defp extract_function_signature({:when, _meta, [signature, _guard]}) do
    # Function with guard
    extract_function_signature(signature)
  end

  defp extract_function_signature({name, _meta, args}) when is_atom(name) do
    arity =
      cond do
        is_nil(args) -> 0
        is_list(args) -> length(args)
        true -> 0
      end

    {name, arity}
  end

  defp extract_function_signature(_), do: {nil, nil}

  defp build_location(line, column) do
    %{
      line: line,
      column: column,
      end_line: nil,
      end_column: nil
    }
  end

  # Erlang extraction

  defp extract_erlang(content) do
    # Parse Erlang code using :erl_scan and :erl_parse
    case :erl_scan.string(String.to_charlist(content)) do
      {:ok, tokens, _} ->
        case :erl_parse.parse_form(tokens) do
          {:ok, form} ->
            {:ok, extract_erlang_form(form)}

          {:error, _reason} ->
            # Try to parse as multiple forms
            extract_erlang_forms(content)
        end

      {:error, reason, _} ->
        Logger.warning("Failed to scan Erlang code: #{inspect(reason)}")
        {:ok, %{}}
    end
  end

  defp extract_erlang_forms(_content) do
    # Split into individual forms and parse each
    # This is a simplified approach - real implementation would need better parsing
    {:ok, %{}}
  end

  defp extract_erlang_form({:function, line, name, arity, _clauses}) do
    func_key = "#{name}/#{arity}"

    %{
      func_key => %{
        line: line,
        column: nil,
        end_line: nil,
        end_column: nil
      }
    }
  end

  defp extract_erlang_form({:attribute, line, :module, module}) do
    module_name = to_string(module)

    %{
      module_name => %{
        line: line,
        column: nil,
        end_line: nil,
        end_column: nil
      }
    }
  end

  defp extract_erlang_form(_other) do
    %{}
  end

  # Language detection

  defp detect_language(path) do
    case Path.extname(path) do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".erl" -> :erlang
      ".hrl" -> :erlang
      ".py" -> :python
      ".rb" -> :ruby
      ".hs" -> :haskell
      _ -> :unknown
    end
  end
end
