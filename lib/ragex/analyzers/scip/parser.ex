defmodule Ragex.Analyzers.SCIP.Parser do
  @moduledoc """
  Parses SCIP index JSON (from `scip print --json`) into Ragex's internal
  analysis format.

  Zero external dependencies -- uses OTP's `:json.decode/1` for parsing
  and maps SCIP's document/symbol/occurrence model to Ragex's
  `%{modules, functions, calls, imports}` shape.

  ## SCIP Model -> Ragex Model Mapping

  - SCIP `Document` -> one or more Ragex modules (grouped by namespace)
  - SCIP `SymbolInformation` with `Suffix.Type` or `Suffix.Namespace` -> `:module` node
  - SCIP `SymbolInformation` with `Suffix.Method` or `Suffix.Term` -> `:function` node
  - SCIP `Occurrence` with definition role -> defines edge
  - SCIP `Occurrence` with reference role -> calls edge
  """

  @doc """
  Parse a SCIP JSON string into Ragex analysis result format.

  ## Parameters
  - `json_string` -- output of `scip print --json index.scip`
  - `project_root` -- absolute path to the project root (for file resolution)

  ## Returns
  `{:ok, analysis_result}` matching `Ragex.Analyzers.Behaviour.analysis_result()`
  """
  @spec parse(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def parse(json_string, project_root) do
    case :json.decode(json_string) do
      index when is_map(index) ->
        documents = Map.get(index, "documents", [])
        external_symbols = Map.get(index, "externalSymbols", [])
        metadata = Map.get(index, "metadata", %{})

        language = get_in(metadata, ["toolInfo", "name"]) || "unknown"

        {modules, functions, calls, imports} =
          Enum.reduce(documents, {[], [], [], []}, fn doc, acc ->
            parse_document(doc, project_root, language, acc)
          end)

        # Also extract external symbol hover docs
        _ext_docs = parse_external_symbols(external_symbols)

        {:ok,
         %{
           modules: Enum.reverse(modules),
           functions: Enum.reverse(functions),
           calls: Enum.reverse(calls),
           imports: Enum.reverse(imports),
           metadata: %{
             tool: language,
             version: get_in(metadata, ["toolInfo", "version"]),
             project_root: Map.get(metadata, "projectRoot"),
             documents_count: length(documents)
           }
         }}

      _ ->
        {:error, :invalid_json}
    end
  rescue
    e -> {:error, {:parse_error, Exception.message(e)}}
  end

  @doc """
  Parse a SCIP JSON string into a simplified flat list of symbols with
  their locations. Useful for quick inspection.
  """
  @spec parse_symbols(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_symbols(json_string) do
    case :json.decode(json_string) do
      index when is_map(index) ->
        documents = Map.get(index, "documents", [])

        symbols =
          Enum.flat_map(documents, fn doc ->
            file = Map.get(doc, "relativePath", "")
            doc_symbols = Map.get(doc, "symbols", [])

            Enum.map(doc_symbols, fn sym ->
              %{
                symbol: Map.get(sym, "symbol", ""),
                file: file,
                documentation: extract_documentation(sym),
                kind: infer_kind(Map.get(sym, "symbol", ""))
              }
            end)
          end)

        {:ok, symbols}

      _ ->
        {:error, :invalid_json}
    end
  rescue
    e -> {:error, {:parse_error, Exception.message(e)}}
  end

  # ── Document parsing ─────────────────────────────────────────────────

  defp parse_document(doc, project_root, language, {mods, funs, calls_acc, imports_acc}) do
    relative_path = Map.get(doc, "relativePath", "")
    file_path = Path.join(project_root, relative_path)
    doc_language = Map.get(doc, "language", language)

    symbols = Map.get(doc, "symbols", [])
    occurrences = Map.get(doc, "occurrences", [])

    # Build symbol table: symbol_string -> SymbolInformation
    symbol_table = Map.new(symbols, fn sym -> {Map.get(sym, "symbol", ""), sym} end)

    # Extract module-level symbol (namespace/type with no parent)
    {new_mods, new_funs} = extract_definitions(symbols, file_path, doc_language)

    # Extract calls from occurrences (references to defined symbols)
    {new_calls, new_imports} = extract_references(occurrences, symbol_table, file_path)

    {new_mods ++ mods, new_funs ++ funs, new_calls ++ calls_acc, new_imports ++ imports_acc}
  end

  defp extract_definitions(symbols, file_path, language) do
    Enum.reduce(symbols, {[], []}, fn sym, {mods, funs} ->
      symbol_str = Map.get(sym, "symbol", "")
      kind = infer_kind(symbol_str)
      {mod_name, func_name, arity} = parse_symbol_string(symbol_str)
      doc = extract_documentation(sym)

      case kind do
        :module ->
          mod = %{
            name: mod_name || symbol_str,
            file: file_path,
            line: 1,
            doc: doc,
            language: language,
            metadata: %{scip_symbol: symbol_str, source: :scip}
          }

          {[mod | mods], funs}

        :function ->
          func = %{
            name: func_name || String.to_atom(last_descriptor(symbol_str)),
            arity: arity || 0,
            module: mod_name || infer_module(symbol_str),
            file: file_path,
            line: 1,
            doc: doc,
            visibility: :public,
            language: language,
            metadata: %{scip_symbol: symbol_str, source: :scip}
          }

          {mods, [func | funs]}

        _ ->
          {mods, funs}
      end
    end)
  end

  defp extract_references(occurrences, _symbol_table, file_path) do
    Enum.reduce(occurrences, {[], []}, fn occ, {calls, imports} ->
      symbol = Map.get(occ, "symbol", "")
      roles = Map.get(occ, "symbolRoles", 0)
      range = Map.get(occ, "range", [])
      line = if is_list(range) and range != [], do: Enum.at(range, 0, 0) + 1, else: 0

      is_definition = Bitwise.band(roles, 0x1) != 0
      is_import = Bitwise.band(roles, 0x8) != 0

      cond do
        is_import ->
          {from_mod, _, _} = parse_symbol_string(symbol)

          imp = %{
            from_module: infer_module_from_file(file_path),
            to_module: from_mod || symbol,
            type: :import
          }

          {calls, [imp | imports]}

        not is_definition and symbol != "" ->
          # This is a reference (call site)
          {to_mod, to_func, to_arity} = parse_symbol_string(symbol)

          call = %{
            from_module: infer_module_from_file(file_path),
            from_function: :unknown,
            from_arity: 0,
            to_module: to_mod || symbol,
            to_function: to_func || :unknown,
            to_arity: to_arity || 0,
            line: line
          }

          {[call | calls], imports}

        true ->
          {calls, imports}
      end
    end)
  end

  # ── Symbol string parsing ────────────────────────────────────────────
  # SCIP symbol format: scheme ' ' manager ' ' package ' ' version ' ' descriptors...
  # Descriptors end with suffixes: / (namespace), # (type), . (term), () (method)

  defp parse_symbol_string("local " <> _), do: {nil, nil, nil}

  defp parse_symbol_string(symbol) when is_binary(symbol) do
    # Extract descriptors (everything after the package info)
    parts = String.split(symbol, " ", trim: true)

    case parts do
      [_scheme, _manager, _package, _version | descriptor_parts] ->
        descriptor = Enum.join(descriptor_parts, " ")
        parse_descriptors(descriptor)

      _ ->
        {nil, nil, nil}
    end
  end

  defp parse_symbol_string(_), do: {nil, nil, nil}

  defp parse_descriptors(descriptor) do
    descriptor_re = ~r/[^\/#.\[\]()]+[\/#.\[\]()]/
    method_end_re = ~r/\([^\)]*\)\.$/
    # Split by descriptor suffixes
    segments =
      descriptor_re
      |> Regex.scan(descriptor)
      |> Enum.map(fn [full | _] -> full end)

    module_parts =
      segments
      |> Enum.filter(fn s -> String.ends_with?(s, "/") or String.ends_with?(s, "#") end)
      |> Enum.map(fn s -> String.trim_trailing(s, "/") |> String.trim_trailing("#") end)

    method_parts =
      segments
      |> Enum.filter(fn s ->
        String.ends_with?(s, ".") or Regex.match?(method_end_re, s)
      end)

    module_name = if module_parts != [], do: Enum.join(module_parts, ".") |> String.to_atom()

    {func_name, arity} =
      case method_parts do
        [method | _] ->
          clean = method |> String.replace(method_end_re, "") |> String.trim_trailing(".")
          {String.to_atom(clean), 0}

        _ ->
          {nil, nil}
      end

    {module_name, func_name, arity}
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp infer_kind(symbol) when is_binary(symbol) do
    cond do
      String.ends_with?(symbol, "#") -> :module
      String.ends_with?(symbol, "/") -> :module
      String.contains?(symbol, "().") -> :function
      String.ends_with?(symbol, ".") -> :function
      String.starts_with?(symbol, "local ") -> :local
      true -> :unknown
    end
  end

  defp infer_kind(_), do: :unknown

  defp infer_module(symbol) do
    case parse_symbol_string(symbol) do
      {mod, _, _} when not is_nil(mod) -> mod
      _ -> String.to_atom(symbol)
    end
  end

  defp infer_module_from_file(file_path) do
    file_path
    |> Path.basename()
    |> Path.rootname()
    |> String.to_atom()
  end

  defp last_descriptor(symbol) do
    simple_ident_re = ~r/([^\/#.\[\]()]+)/
    parts = Regex.scan(simple_ident_re, symbol) |> Enum.map(fn [_, m] -> m end)
    List.last(parts) || "unknown"
  end

  defp extract_documentation(sym) do
    case Map.get(sym, "documentation") do
      docs when is_list(docs) -> Enum.join(docs, "\n")
      doc when is_binary(doc) -> doc
      _ -> nil
    end
  end

  defp parse_external_symbols(ext_symbols) do
    Map.new(ext_symbols, fn sym ->
      {Map.get(sym, "symbol", ""), extract_documentation(sym)}
    end)
  end
end
