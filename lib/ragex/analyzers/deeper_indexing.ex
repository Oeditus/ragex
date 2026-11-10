defmodule Ragex.Analyzers.DeeperIndexing do
  @moduledoc """
  Post-processing pass that extracts string literals and comments from source
  code and associates them with the nearest function in the analysis result.

  This enriches the knowledge graph with deeper metadata enabling:

  - Searching for SQL queries, error messages, and domain terms inside code.
  - Associating inline TODO/HACK/FIXME comments with specific functions.
  - Keyword-boosted semantic search via `Ragex.Search.Keywords`.

  ## Supported Languages

  - **Elixir** -- walks the AST for binary literals; re-uses line-based comment
    extraction.
  - **Erlang** -- walks parsed forms for `{string, Line, Chars}` tuples; regex
    for `%`-style comments.
  - **Python** -- regex extraction of `"..."` / `'...'` / triple-quoted strings
    and `#`-style comments.
  - **JavaScript/TypeScript** -- regex extraction of string literals, template
    literals, and `//` / `/* */` comments.
  - **Markdown** -- headings are indexed as structural markers, link and image
    destinations as strings, and prose paragraphs as searchable text. Fenced
    and indented code blocks are skipped so documentation is never polluted by
    the code samples it embeds.

  ## Documentation Languages

  Markdown has no functions, so every extracted item is associated with
  `:module_level`. `Ragex.Analyzers.Metastatic` materialises a single document
  entity for such files, which is what makes the prose reachable from search.

  ## Usage

      {:ok, analysis} = Ragex.Analyzers.Elixir.analyze(source, path)
      enrichment = DeeperIndexing.extract(source, path, analysis)
      # => %{strings: %{{mod, func, arity} => ["INSERT INTO ...", ...]},
      #      comments: %{{mod, func, arity} => ["TODO: refactor", ...]}}
  """

  @type func_key :: {atom(), atom(), non_neg_integer()} | :module_level
  @type enrichment :: %{
          strings: %{func_key() => [String.t()]},
          comments: %{func_key() => [String.t()]}
        }

  @doc """
  Extract string literals and comments from source code, associating each
  with the nearest function from the analysis result.

  ## Parameters

  - `source` -- raw source code string
  - `file_path` -- path used for language detection
  - `analysis` -- the `%{functions: [...], ...}` map from an analyzer

  ## Returns

  `%{strings: %{func_key => [str, ...]}, comments: %{func_key => [str, ...]}}`
  where `func_key` is `{module, name, arity}` or `:module_level`.
  """
  @spec extract(String.t(), String.t(), map()) :: enrichment()
  def extract(source, file_path, analysis) do
    language = detect_language(file_path)
    functions = Map.get(analysis, :functions, [])

    # Build sorted function ranges for proximity matching
    func_ranges = build_function_ranges(functions)

    strings = extract_strings(source, language)
    comments = extract_comments(source, language)

    %{
      strings: associate_with_functions(strings, func_ranges),
      comments: associate_with_functions(comments, func_ranges)
    }
  end

  @doc """
  Merge enrichment data into function metadata maps.

  Takes the enrichment from `extract/3` and the original analysis, returning
  updated function info maps with `:strings`, `:comments` added to metadata.
  """
  @spec merge_into_analysis(enrichment(), map()) :: map()
  def merge_into_analysis(enrichment, analysis) do
    updated_functions =
      Enum.map(analysis.functions, fn func ->
        key = {func.module, func.name, func.arity}
        strings = Map.get(enrichment.strings, key, [])
        comments = Map.get(enrichment.comments, key, [])

        new_metadata =
          func.metadata
          |> Map.put(:strings, strings)
          |> Map.put(:comments, comments)

        %{func | metadata: new_metadata}
      end)

    %{analysis | functions: updated_functions}
  end

  # ── Language Detection ──────────────────────────────────────────────

  # ── Language Detection ──────────────────────────────────────────────

  defp detect_language(file_path), do: Ragex.LanguageSupport.detect_language(file_path)

  # ── String Extraction ───────────────────────────────────────────────

  @doc """
  Extract string literals with line numbers from source code.

  Returns a list of `{line, string_content}` tuples.
  """
  @spec extract_strings(String.t(), atom()) :: [{pos_integer(), String.t()}]
  def extract_strings(source, :elixir) do
    # Use regex for reliable string extraction from Elixir source.
    # The AST walk misses many strings because the compiler inlines them.
    extract_strings_regex(source, ~r/"([^"\\]|\\.)*"/, 1)
  end

  def extract_strings(source, :erlang) do
    # Erlang strings are in double quotes
    extract_strings_regex(source, ~r/"([^"\\]|\\.)*"/, 1)
  end

  def extract_strings(source, :python) do
    # Triple-quoted strings first (greedy), then single/double quoted
    triple = extract_strings_regex(source, ~r/"""([\s\S]*?)"""|'''([\s\S]*?)'''/, 0)

    single =
      extract_strings_regex(
        source,
        ~r/(?<!["'])("[^"\\]*(?:\\.[^"\\]*)*"|'[^'\\]*(?:\\.[^'\\]*)*')/,
        1
      )

    Enum.sort_by(triple ++ single, &elem(&1, 0))
  end

  def extract_strings(source, lang) when lang in [:javascript, :typescript] do
    # Template literals, double-quoted, single-quoted
    templates = extract_strings_regex(source, ~r/`([^`\\]|\\.)*`/, 0)

    quoted =
      extract_strings_regex(source, ~r/("[^"\\]*(?:\\.[^"\\]*)*"|'[^'\\]*(?:\\.[^'\\]*)*')/, 1)

    Enum.sort_by(templates ++ quoted, &elem(&1, 0))
  end

  def extract_strings(source, :java) do
    # Multi-line text blocks (Java 15+)
    text_blocks =
      Regex.scan(~r/"""([\s\S]*?)"""/, source)
      |> Enum.flat_map(fn [full_match, content] ->
        before = String.split(source, full_match) |> hd()
        line_num = length(String.split(before, "\n"))
        [{line_num, String.trim(content)}]
      end)

    strings = extract_strings_regex(source, ~r/"([^"\\]|\\.)*"/, 1)

    Enum.sort_by(text_blocks ++ strings, &elem(&1, 0))
  end

  def extract_strings(source, lang) when lang in [:haskell, :agda, :cure] do
    extract_strings_regex(source, ~r/"([^"\\]|\\.)*"/, 1)
  end

  # Markdown has no string literals. What is worth indexing is the *destination*
  # of links and images: those are the URLs and paths a reader would search for.
  # Bare URLs are included too, since autolinks and plain references are common.
  def extract_strings(source, :markdown) do
    source
    |> markdown_prose_lines()
    |> Enum.flat_map(fn {line_num, line} ->
      markdown_destinations(line)
      |> Enum.map(fn destination -> {line_num, destination} end)
    end)
    |> Enum.reject(fn {_line, destination} -> String.length(destination) < 3 end)
  end

  def extract_strings(_source, _language), do: []

  defp extract_strings_regex(source, regex, _group) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_num} ->
      Regex.scan(regex, line)
      |> Enum.map(fn
        [match | _] ->
          # Strip surrounding quotes
          content = strip_quotes(match)

          if String.length(content) >= 3 do
            {line_num, content}
          else
            nil
          end
      end)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp strip_quotes(str) do
    str
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
    |> String.trim_leading("`")
    |> String.trim_trailing("`")
    |> String.trim_leading("\"\"\"")
    |> String.trim_trailing("\"\"\"")
    |> String.trim_leading("'''")
    |> String.trim_trailing("'''")
  end

  # ── Comment Extraction ──────────────────────────────────────────────

  @doc """
  Extract comments with line numbers from source code.

  Returns a list of `{line, comment_text}` tuples.
  Merges consecutive comment lines into single blocks.
  """
  @spec extract_comments(String.t(), atom()) :: [{pos_integer(), String.t()}]
  def extract_comments(source, :elixir) do
    extract_line_comments(source, ~r/^\s*#\s*(.*)$/)
  end

  def extract_comments(source, :erlang) do
    extract_line_comments(source, ~r/^\s*%+\s*(.*)$/)
  end

  def extract_comments(source, :python) do
    extract_line_comments(source, ~r/^\s*#\s*(.*)$/)
  end

  def extract_comments(source, lang) when lang in [:javascript, :typescript, :java] do
    line_comments = extract_line_comments(source, ~r|^\s*//\s*(.*)$|)

    # Block comments: /* ... */
    block_comments =
      Regex.scan(~r|/\*\s*([\s\S]*?)\s*\*/|, source)
      |> Enum.flat_map(fn [full_match, content] ->
        # Find the line number of the block comment
        before = String.split(source, full_match) |> hd()
        line_num = length(String.split(before, "\n"))
        [{line_num, String.trim(content)}]
      end)

    Enum.sort_by(line_comments ++ block_comments, &elem(&1, 0))
  end

  def extract_comments(source, lang) when lang in [:haskell, :agda] do
    line_comments = extract_line_comments(source, ~r/^\s*--\s*(.*)$/)

    block_comments =
      Regex.scan(~r/\{-\s*([\s\S]*?)\s*-\}/, source)
      |> Enum.flat_map(fn [full_match, content] ->
        before = String.split(source, full_match) |> hd()
        line_num = length(String.split(before, "\n"))
        [{line_num, String.trim(content)}]
      end)

    Enum.sort_by(line_comments ++ block_comments, &elem(&1, 0))
  end

  def extract_comments(source, :cure) do
    extract_line_comments(source, ~r/^\s*#+\s*(.*)$/)
  end

  # A Markdown document is *entirely* prose, so there is nothing to single out
  # as a "comment". Headings are the closest structural equivalent: they carry
  # the document's topic vocabulary and are what readers navigate by.
  def extract_comments(source, :markdown) do
    source
    |> markdown_prose_lines()
    |> Enum.flat_map(fn {line_num, line} ->
      case Regex.run(~r/^\s{0,3}(\#{1,6})\s+(.+?)\s*#*\s*$/, line) do
        [_, hashes, text] -> [{line_num, String.trim(text), String.length(hashes)}]
        _ -> []
      end
    end)
    |> Enum.reduce([], fn {line_num, text, _level}, acc ->
      case acc do
        # Merge consecutive heading lines, which is how wrapped ATX headings
        # and adjacent setext titles are commonly written.
        [{prev_line, prev_text} | rest] when line_num - prev_line == 1 ->
          [{line_num, prev_text <> " " <> text} | rest]

        _ ->
          [{line_num, text} | acc]
      end
    end)
    |> Enum.reverse()
  end

  def extract_comments(_source, _language), do: []

  defp extract_line_comments(source, regex) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {line, line_num}, acc ->
      case Regex.run(regex, line) do
        [_, comment_text] ->
          text = String.trim(comment_text)

          if String.length(text) > 0 do
            case acc do
              # Merge consecutive comment lines
              [{prev_line, prev_text} | rest] when line_num - prev_line == 1 ->
                [{line_num, prev_text <> " " <> text} | rest]

              _ ->
                [{line_num, text} | acc]
            end
          else
            acc
          end

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  # ── Markdown Helpers ────────────────────────────────────────────────

  # Returns `{line_number, line}` pairs for everything that is *not* inside a
  # fenced or indented code block. Code samples are skipped deliberately: a
  # `def hello` inside a fenced block is documentation *about* code, not a
  # symbol of the document, and indexing it would create phantom matches.
  defp markdown_prose_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil}, fn {line, line_num}, {acc, fence} ->
      case fence do
        nil ->
          cond do
            fence_open?(line) ->
              {acc, fence_marker(line)}

            indented_code?(line) ->
              {acc, :indented}

            true ->
              {[{line_num, line} | acc], nil}
          end

        :indented ->
          # An indented block ends at the first non-blank, non-indented line.
          if String.trim(line) == "" or indented_code?(line) do
            {acc, :indented}
          else
            {[{line_num, line} | acc], nil}
          end

        marker ->
          # A fenced block ends only at a fence of the same character.
          if fence_open?(line) and fence_marker(line) == marker do
            {acc, nil}
          else
            {acc, marker}
          end
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp fence_open?(line) do
    line |> String.trim_leading() |> fence_marker() |> Kernel.!=(nil)
  end

  defp fence_marker(line) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "```") -> "```"
      String.starts_with?(trimmed, "~~~") -> "~~~"
      true -> nil
    end
  end

  defp indented_code?(line) do
    String.trim(line) != "" and
      (String.starts_with?(line, "    ") or String.starts_with?(line, "\t"))
  end

  # Extracts link/image destinations and bare URLs from a single line.
  # Inline code spans are stripped first so `[x](y)` inside backticks is not
  # mistaken for a real link.
  defp markdown_destinations(line) do
    cleaned = Regex.replace(~r/`[^`]*`/, line, " ")

    bracketed =
      Regex.scan(~r/!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?[^)]*\)/, cleaned, capture: :all_but_first)
      |> List.flatten()

    autolinks =
      Regex.scan(~r/<((?:https?|mailto):[^>\s]+)>/, cleaned, capture: :all_but_first)
      |> List.flatten()

    bare_urls =
      Regex.scan(~r/(?:^|\s)((?:https?|ftp):\/\/[^\s<>)\]]+)/, cleaned, capture: :all_but_first)
      |> List.flatten()

    (bracketed ++ autolinks ++ bare_urls)
    |> Enum.map(&String.trim_trailing(&1, "."))
    |> Enum.uniq()
  end

  # ── Function Association ────────────────────────────────────────────

  defp build_function_ranges(functions) do
    functions
    |> Enum.map(fn func ->
      {func.line, {func.module, func.name, func.arity}}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp associate_with_functions(items, func_ranges) do
    items
    |> Enum.reduce(%{}, fn {line, content}, acc ->
      key = find_enclosing_function(line, func_ranges)
      Map.update(acc, key, [content], &[content | &1])
    end)
    |> Enum.into(%{}, fn {key, values} -> {key, Enum.reverse(values)} end)
  end

  # Find the function whose definition line is closest to and <= the item line
  defp find_enclosing_function(line, func_ranges) do
    func_ranges
    |> Enum.filter(fn {func_line, _key} -> func_line <= line end)
    |> Enum.max_by(fn {func_line, _key} -> func_line end, fn -> nil end)
    |> case do
      {_line, key} -> key
      nil -> :module_level
    end
  end
end
