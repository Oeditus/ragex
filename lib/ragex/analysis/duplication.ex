defmodule Ragex.Analysis.Duplication do
  @moduledoc """
  Code duplication detection using two complementary approaches.

  ## Primary: AST-Based Detection (via Metastatic)

  Delegates to Metastatic.Analysis.Duplication for precise clone detection:
  - **Type I**: Exact clones (identical AST)
  - **Type II**: Renamed clones (same structure, different identifiers)
  - **Type III**: Near-miss clones (similar structure with modifications)
  - **Type IV**: Semantic clones (different syntax, same behavior)

  Works across different programming languages by comparing MetaAST representations.

  ## Secondary: Embedding-Based Detection

  Uses existing semantic embeddings to find similar functions:
  - Semantic similarity via cosine distance
  - Configurable similarity threshold (default: 0.95)
  - Complements AST-based detection
  - Useful for finding "code smells" and refactoring opportunities

  ## Usage

      alias Ragex.Analysis.Duplication

      # AST-based detection (via Metastatic)
      {:ok, result} = Duplication.detect_in_files(["lib/a.ex", "lib/b.ex"])
      
      # Embedding-based detection
      {:ok, similar} = Duplication.find_similar_functions(threshold: 0.95)
      
      # Detect in directory
      {:ok, results} = Duplication.detect_in_directory("lib/")
  """

  alias Metastatic.Analysis.Duplication, as: MetaDuplication
  alias Ragex.{Analysis.MetastaticBridge, Graph.Store, VectorStore}

  require Logger

  @type clone_type :: :type_i | :type_ii | :type_iii | :type_iv
  @type clone_pair :: %{
          file1: String.t(),
          file2: String.t(),
          clone_type: clone_type(),
          similarity: float(),
          details: map()
        }

  @type similar_pair :: %{
          function1: function_ref(),
          function2: function_ref(),
          similarity: float(),
          method: :embedding | :ast
        }

  @type function_ref :: {:function, module(), atom(), non_neg_integer()}

  @doc """
  Detects duplicates between two files using Metastatic's AST comparison.

  ## Parameters
  - `file1_path` - Path to first file
  - `file2_path` - Path to second file
  - `opts` - Keyword list of options
    - `:threshold` - Similarity threshold for Type III (default: 0.8)
    - `:min_tokens` - Minimum tokens for detection (default: 5)
    - `:cross_language` - Enable cross-language detection (default: true)

  ## Returns
  - `{:ok, result}` - Metastatic.Analysis.Duplication.Result struct
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      {:ok, result} = Duplication.detect_between_files("lib/a.ex", "lib/b.ex")
      if result.duplicate? do
        IO.puts("Found \#{result.clone_type} clone")
      end
  """
  @spec detect_between_files(String.t(), String.t(), keyword()) ::
          {:ok, Metastatic.Analysis.Duplication.Result.t()} | {:error, term()}
  def detect_between_files(file1_path, file2_path, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.8)

    with {:ok, doc1} <- MetastaticBridge.parse_file(file1_path),
         {:ok, doc2} <- MetastaticBridge.parse_file(file2_path) do
      MetaDuplication.detect(doc1, doc2, threshold: threshold)
    else
      {:error, reason} = error ->
        Logger.warning(
          "Failed to detect duplicates between #{file1_path} and #{file2_path}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Detects duplicates across multiple files.

  Returns a list of clone pairs found across the provided files.

  ## Parameters
  - `file_paths` - List of file paths to analyze
  - `opts` - Keyword list of options (same as detect_between_files/3)

  ## Returns
  - `{:ok, [clone_pair]}` - List of detected clone pairs
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      {:ok, clones} = Duplication.detect_in_files(["lib/a.ex", "lib/b.ex", "lib/c.ex"])
      Enum.each(clones, fn clone ->
        IO.puts("\#{clone.file1} <-> \#{clone.file2}: \#{clone.clone_type}")
      end)
  """
  @spec detect_in_files([String.t()], keyword()) :: {:ok, [clone_pair()]} | {:error, term()}
  def detect_in_files(file_paths, opts \\ []) when is_list(file_paths) do
    # Parse all files
    documents =
      file_paths
      |> Enum.map(fn path ->
        case MetastaticBridge.parse_file(path) do
          {:ok, doc} -> {path, doc}
          {:error, reason} -> {path, {:error, reason}}
        end
      end)
      |> Enum.filter(fn {_path, result} -> not match?({:error, _}, result) end)

    # Compare all pairs
    clones =
      for {path1, doc1} <- documents,
          {path2, doc2} <- documents,
          path1 < path2 do
        case MetaDuplication.detect(doc1, doc2, opts) do
          {:ok, result} ->
            if result.duplicate? do
              %{
                file1: path1,
                file2: path2,
                clone_type: result.clone_type,
                similarity: result.similarity_score,
                details: %{
                  locations: result.locations || [],
                  summary: result.summary || ""
                }
              }
            else
              nil
            end
        end
      end
      |> Enum.filter(&(&1 != nil))

    {:ok, clones}
  rescue
    e ->
      Logger.error("Failed to detect duplicates in files: #{inspect(e)}")
      {:error, {:analysis_failed, Exception.message(e)}}
  end

  @doc """
  Detects duplicates in all supported files within a directory.

  Recursively scans the directory for supported file types and detects
  duplicates using Metastatic's AST comparison.

  ## Parameters
  - `directory` - Path to directory
  - `opts` - Keyword list of options
    - `:recursive` - Recursively scan subdirectories (default: true)
    - `:threshold` - Similarity threshold (default: 0.8)
    - `:exclude_patterns` - List of patterns to exclude (default: ["_build", "deps", ".git"])

  ## Returns
  - `{:ok, [clone_pair]}` - List of detected clone pairs
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      {:ok, clones} = Duplication.detect_in_directory("lib/")
      IO.puts("Found \#{length(clones)} duplicate pairs")
  """
  @spec detect_in_directory(String.t(), keyword()) :: {:ok, [clone_pair()]} | {:error, term()}
  def detect_in_directory(directory, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, true)
    exclude_patterns = Keyword.get(opts, :exclude_patterns, ["_build", "deps", ".git"])

    case find_supported_files(directory, recursive, exclude_patterns) do
      [] ->
        {:ok, []}

      files ->
        detect_in_files(files, opts)
    end
  end

  @doc """
  Finds similar functions using semantic embeddings.

  This is a complementary approach to AST-based detection. Uses cosine
  similarity on function embeddings to find semantically similar code.

  ## Parameters
  - `opts` - Keyword list of options
    - `:threshold` - Similarity threshold (0.0-1.0, default: 0.95)
    - `:limit` - Maximum number of pairs to return (default: 100)
    - `:node_type` - Type of node to compare (default: :function)

  ## Returns
  - `{:ok, [similar_pair]}` - List of similar function pairs
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      {:ok, similar} = Duplication.find_similar_functions(threshold: 0.95)
      Enum.each(similar, fn pair ->
        IO.puts("\#{format_function(pair.function1)} ~ \#{format_function(pair.function2)}")
        IO.puts("  Similarity: \#{pair.similarity}")
      end)
  """
  @spec find_similar_functions(keyword()) :: {:ok, [similar_pair()]} | {:error, term()}
  def find_similar_functions(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.95)
    limit = Keyword.get(opts, :limit, 100)
    node_type = Keyword.get(opts, :node_type, :function)

    try do
      # Get all embeddings
      embeddings = Store.list_embeddings(node_type)

      # Find similar pairs by comparing all embeddings
      similar_pairs =
        embeddings
        |> Enum.flat_map(fn {_type1, id1, emb1, _text1} ->
          embeddings
          |> Enum.filter(fn {_type2, id2, _emb2, _text2} -> id1 != id2 end)
          |> Enum.map(fn {_type2, id2, emb2, _text2} ->
            similarity = VectorStore.cosine_similarity(emb1, emb2)
            {id1, id2, similarity}
          end)
          |> Enum.filter(fn {_id1, _id2, sim} -> sim >= threshold end)
          |> Enum.map(fn {id1, id2, sim} ->
            %{
              function1: id1,
              function2: id2,
              similarity: sim,
              method: :embedding
            }
          end)
        end)
        |> Enum.sort_by(& &1.similarity, :desc)
        |> Enum.take(limit)
        # Remove duplicates (A-B and B-A)
        |> deduplicate_pairs()

      {:ok, similar_pairs}
    rescue
      e ->
        Logger.error("Failed to find similar functions: #{inspect(e)}")
        {:error, {:analysis_failed, Exception.message(e)}}
    end
  end

  @doc """
  Generates a duplication report for a project.

  Combines both AST-based and embedding-based detection to provide
  a comprehensive view of code duplication.

  ## Parameters
  - `directory` - Path to project directory
  - `opts` - Keyword list of options
    - `:include_embeddings` - Include embedding-based results (default: true)
    - `:format` - Output format (:summary, :detailed, :json, default: :summary)

  ## Returns
  - `{:ok, report}` - Duplication report map
  - `{:error, reason}` - Error if analysis fails
  """
  @spec generate_report(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_report(directory, opts \\ []) do
    include_embeddings = Keyword.get(opts, :include_embeddings, true)

    with {:ok, ast_clones} <- detect_in_directory(directory, opts),
         {:ok, embedding_similar} <-
           if(include_embeddings, do: find_similar_functions(opts), else: {:ok, []}) do
      report = %{
        directory: directory,
        ast_clones: %{
          total: length(ast_clones),
          by_type: group_by_clone_type(ast_clones),
          pairs: ast_clones
        },
        embedding_similar: %{
          total: length(embedding_similar),
          pairs: embedding_similar
        },
        summary: build_summary(ast_clones, embedding_similar)
      }

      {:ok, report}
    end
  end

  # Private functions

  defp find_supported_files(dir, recursive, exclude_patterns) do
    extensions = [".ex", ".exs", ".erl", ".hrl", ".py", ".rb", ".hs"]

    pattern = if recursive, do: Path.join(dir, "**/*"), else: Path.join(dir, "*")

    Path.wildcard(pattern)
    |> Enum.filter(fn path ->
      File.regular?(path) &&
        Enum.any?(extensions, fn ext -> String.ends_with?(path, ext) end) &&
        not excluded?(path, exclude_patterns)
    end)
  end

  defp excluded?(path, patterns) do
    Enum.any?(patterns, fn pattern ->
      String.contains?(path, pattern)
    end)
  end

  defp deduplicate_pairs(pairs) do
    pairs
    |> Enum.reduce({MapSet.new(), []}, fn pair, {seen, acc} ->
      # Create a canonical key (smaller id first)
      key =
        [pair.function1, pair.function2]
        |> Enum.sort()
        |> List.to_tuple()

      if MapSet.member?(seen, key) do
        {seen, acc}
      else
        {MapSet.put(seen, key), [pair | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp group_by_clone_type(clones) do
    Enum.reduce(clones, %{}, fn clone, acc ->
      Map.update(acc, clone.clone_type, 1, &(&1 + 1))
    end)
  end

  defp build_summary(ast_clones, embedding_similar) do
    ast_clones_count = length(ast_clones)
    embedding_similar_count = length(embedding_similar)

    """
    Duplication Analysis Summary
    ============================
    AST-Based Clones: #{ast_clones_count}
    #{if ast_clones_count do
      type_counts = group_by_clone_type(ast_clones)

      type_counts |> Enum.map_join("\n", fn {type, count} -> "  - #{format_clone_type(type)}: #{count}" end)
    else
      "  (none)"
    end}

    Embedding-Based Similar Code: #{embedding_similar_count}
    #{if embedding_similar_count > 0 do
      "  Average similarity: #{average_similarity(embedding_similar)}"
    else
      "  (none)"
    end}
    """
    |> String.trim()
  end

  defp format_clone_type(:type_i), do: "Type I (Exact)"
  defp format_clone_type(:type_ii), do: "Type II (Renamed)"
  defp format_clone_type(:type_iii), do: "Type III (Near-miss)"
  defp format_clone_type(:type_iv), do: "Type IV (Semantic)"
  defp format_clone_type(other), do: to_string(other)

  defp average_similarity([]), do: 0.0

  defp average_similarity(pairs) do
    sum = Enum.sum(Enum.map(pairs, & &1.similarity))
    Float.round(sum / length(pairs), 2)
  end
end
