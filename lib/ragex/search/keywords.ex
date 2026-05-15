defmodule Ragex.Search.Keywords do
  @moduledoc """
  Extracts weighted keywords from code entities for boosted semantic search.

  Keywords are extracted from multiple sources with differential boosting:

  - **Documentation** (1.5x) -- highest signal, written by humans for humans.
  - **Function/module names** (1.0x) -- camelCase/snake_case split into tokens.
  - **Type specs** (0.9x) -- parameter and return types.
  - **String literals** (0.8x) -- SQL, error messages, domain terms.
  - **Comments** (0.6x) -- lowest signal, often informal.

  ## Usage

      func_info = %{name: :create_user, module: MyApp.Accounts, arity: 2,
                     doc: "Creates a new user", metadata: %{
                       strings: ["INSERT INTO users"],
                       comments: ["TODO: add validation"]}}
      keywords = Keywords.extract(func_info)
      # => %{"create" => 1.0, "user" => 1.5, "INSERT" => 0.8, ...}

  Keywords are stored in the graph as function metadata and used by
  `VectorStore` during hybrid search for result boosting.
  """

  @doc_boost 1.5
  @name_boost 1.0
  @spec_boost 0.9
  @string_boost 0.8
  @comment_boost 0.6

  @stop_words MapSet.new(~w[
    the a an is are was were be been being have has had do does did
    will would shall should may might can could and or but not no nor
    for to from by with at in on of it its this that these those
    def defp defmodule end do fn true false nil when if else case cond
    import require use alias
    function return var let const class new self cls def async await
    module exports require
  ])

  @type keyword_map :: %{String.t() => float()}

  @doc """
  Extract weighted keywords from a function info map.

  ## Parameters

  - `func_info` -- map with keys `:name`, `:module`, `:doc`, `:spec`,
    and `:metadata` (containing optional `:strings` and `:comments` lists).

  ## Returns

  `%{keyword => weight}` where weight reflects the source boost.
  """
  @spec extract(map()) :: keyword_map()
  def extract(func_info) do
    %{}
    |> merge_keywords(extract_from_names(func_info), @name_boost)
    |> merge_keywords(extract_from_doc(func_info), @doc_boost)
    |> merge_keywords(extract_from_spec(func_info), @spec_boost)
    |> merge_keywords(extract_from_strings(func_info), @string_boost)
    |> merge_keywords(extract_from_comments(func_info), @comment_boost)
  end

  @doc """
  Extract keywords from a module info map.

  Simpler than function extraction: uses module name and documentation.
  """
  @spec extract_module(map()) :: keyword_map()
  def extract_module(module_info) do
    %{}
    |> merge_keywords(tokenize_name(module_info.name), @name_boost)
    |> merge_keywords(tokenize_text(module_info[:doc] || ""), @doc_boost)
  end

  @doc """
  Compute a relevance boost for a search result based on keyword overlap.

  Returns a float multiplier (1.0 = no boost, higher = more relevant).
  """
  @spec relevance_boost(keyword_map(), [String.t()]) :: float()
  def relevance_boost(keywords, query_terms) do
    if map_size(keywords) == 0 or query_terms == [] do
      1.0
    else
      matching_weight =
        query_terms
        |> Enum.reduce(0.0, fn term, acc ->
          normalized = String.downcase(term)
          acc + Map.get(keywords, normalized, 0.0)
        end)

      # Normalize by number of query terms
      avg_weight = matching_weight / length(query_terms)
      # Scale: 0 match = 1.0x, full match = up to 2.0x
      1.0 + min(avg_weight, 1.0)
    end
  end

  # ── Private Extractors ──────────────────────────────────────────────

  defp extract_from_names(func_info) do
    func_tokens = tokenize_name(func_info.name)
    module_tokens = tokenize_name(func_info.module)
    func_tokens ++ module_tokens
  end

  defp extract_from_doc(func_info) do
    tokenize_text(func_info[:doc] || "")
  end

  defp extract_from_spec(func_info) do
    tokenize_text(func_info[:spec] || "")
  end

  defp extract_from_strings(func_info) do
    strings = get_in(func_info, [:metadata, :strings]) || []

    strings
    |> Enum.flat_map(&tokenize_text/1)
  end

  defp extract_from_comments(func_info) do
    comments = get_in(func_info, [:metadata, :comments]) || []

    comments
    |> Enum.flat_map(&tokenize_text/1)
  end

  # ── Tokenization ────────────────────────────────────────────────────

  @doc """
  Split a name (atom or string) into lowercase keyword tokens.

  Handles `snake_case`, `CamelCase`, and dot-separated module names.

  ## Examples

      iex> Keywords.tokenize_name(:create_user)
      ["create", "user"]

      iex> Keywords.tokenize_name(MyApp.UserAccounts)
      ["my", "app", "user", "accounts"]
  """
  @spec tokenize_name(atom() | String.t()) :: [String.t()]
  def tokenize_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.replace(~r/^Elixir\./, "")
    |> tokenize_name()
  end

  def tokenize_name(name) when is_binary(name) do
    name
    |> String.replace(".", " ")
    |> String.replace("_", " ")
    # Split camelCase
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(stop_word?(&1) or String.length(&1) < 2))
  end

  @doc """
  Tokenize free-form text (docs, comments, strings) into keywords.

  Strips punctuation and filters stop words.
  """
  @spec tokenize_text(String.t()) :: [String.t()]
  def tokenize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/[^\w\s-]/, " ")
    |> String.replace("_", " ")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(stop_word?(&1) or String.length(&1) < 2))
  end

  def tokenize_text(_), do: []

  # ── Helpers ─────────────────────────────────────────────────────────

  defp merge_keywords(map, tokens, boost) do
    Enum.reduce(tokens, map, fn token, acc ->
      # Keep the highest boost for each keyword
      Map.update(acc, token, boost, &max(&1, boost))
    end)
  end

  defp stop_word?(word), do: MapSet.member?(@stop_words, word)
end
