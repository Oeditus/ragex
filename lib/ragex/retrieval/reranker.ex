defmodule Ragex.Retrieval.Reranker do
  @moduledoc """
  LLM-based reranker: improves precision after initial retrieval.

  After `Hybrid.search/2` returns a candidate set, this module sends a
  lightweight LLM prompt asking the model to score each candidate's relevance
  to the query on a 0–10 scale.  The original retrieval scores are then blended
  with the LLM scores, and the result set is re-sorted.

  ## When to use

  Call `rerank/3` only when retrieval precision matters more than latency
  (e.g. `rag_query` with a small limit). Skip it for interactive search where
  sub-second response times are required.

  ## Blending

  Final score = `alpha * normalized_llm_score + (1 - alpha) * original_score`

  Default `alpha: 0.6` weights the LLM judgment heavier than the embedding
  distance.  Pass `alpha: 0.0` to use LLM scores alone, or `alpha: 1.0` to
  fall back to original scores only (effectively a no-op).

  ## Batching

  All candidates are sent in a single prompt to minimise latency and cost.
  The LLM is instructed to return a JSON array of `{index, score}` objects.
  If parsing fails, the original ordering is preserved.

  ## Options

  - `:alpha`           - blend weight for LLM score (default: 0.6)
  - `:provider`        - override AI provider (default: configured default)
  - `:max_candidates`  - truncate candidate list before sending to LLM
                         (default: 20)
  - `:timeout`         - milliseconds for LLM call (default: 15_000)
  """

  require Logger

  alias Ragex.AI.Config

  @default_alpha 0.6
  @default_max_candidates 20
  @default_timeout 15_000

  @doc """
  Rerank `candidates` against `query` using a single LLM relevance-scoring call.

  Returns the candidates list re-sorted by blended score. If the LLM call
  fails or parsing fails, the original list is returned unchanged.
  """
  @spec rerank([map()], String.t(), keyword()) :: [map()]
  def rerank(candidates, query, opts \\ []) do
    alpha = Keyword.get(opts, :alpha, @default_alpha)
    max_c = Keyword.get(opts, :max_candidates, @default_max_candidates)
    provider = resolve_provider(opts)

    subset = Enum.take(candidates, max_c)
    remainder = Enum.drop(candidates, max_c)

    case score_with_llm(subset, query, provider, opts) do
      {:ok, llm_scores} ->
        reranked =
          subset
          |> Enum.with_index()
          |> Enum.map(fn {candidate, i} ->
            llm_score = Map.get(llm_scores, i, 5.0) / 10.0
            original = candidate[:score] || candidate[:fusion_score] || 0.0
            blended = alpha * llm_score + (1 - alpha) * original
            Map.put(candidate, :rerank_score, Float.round(blended, 4))
          end)
          |> Enum.sort_by(& &1.rerank_score, :desc)

        reranked ++ remainder

      {:error, reason} ->
        Logger.debug("Reranker LLM call failed (original order preserved): #{inspect(reason)}")
        candidates
    end
  end

  @doc """
  True if the LLM reranker is available (a provider is configured and
  reranking has not been explicitly disabled via config).
  """
  @spec available?() :: boolean()
  def available? do
    Application.get_env(:ragex, :reranker_enabled, true) and
      not is_nil(Config.api_config().api_key)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp score_with_llm(candidates, query, provider, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    prompt = build_prompt(query, candidates)

    task =
      Task.async(fn ->
        provider.generate(prompt, %{}, temperature: 0.0, max_tokens: 512)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, %{content: content}}} ->
        parse_scores(content)

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        {:error, :timeout}
    end
  end

  defp build_prompt(query, candidates) do
    snippets =
      candidates
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {c, i} ->
        id = format_id(c)
        text = String.slice(c[:text] || c[:doc] || "", 0, 300)
        "#{i}: [#{id}] #{text}"
      end)

    """
    You are a code search relevance judge.

    Query: #{query}

    Rate each candidate's relevance to the query on a scale of 0-10.
    Return ONLY a JSON array like: [{"index": 0, "score": 7}, {"index": 1, "score": 3}, ...]
    No explanation, no markdown, only the JSON array.

    Candidates:
    #{snippets}
    """
  end

  defp parse_scores(content) when is_binary(content) do
    json_str =
      content
      |> String.trim()
      |> extract_json_array()

    case Jason.decode(json_str || "[]") do
      {:ok, list} when is_list(list) ->
        scores =
          Map.new(list, fn item ->
            idx = item["index"] || item[:index] || 0
            score = item["score"] || item[:score] || 5.0
            {idx, score / 1.0}
          end)

        {:ok, scores}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp parse_scores(_), do: {:error, :unexpected_content}

  defp extract_json_array(str) do
    case Regex.run(~r/\[.*\]/s, str) do
      [match] -> match
      _ -> nil
    end
  end

  defp format_id(%{node_id: {mod, name, arity}}), do: "#{mod}.#{name}/#{arity}"
  defp format_id(%{node_id: id}) when is_atom(id), do: Atom.to_string(id)
  defp format_id(%{node_id: id}), do: inspect(id)
  defp format_id(_), do: "unknown"

  defp resolve_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil -> Config.provider()
      atom when is_atom(atom) -> provider_module(atom)
    end
  end

  defp provider_module(:deepseek_r1), do: Ragex.AI.Provider.DeepSeekR1
  defp provider_module(:openai), do: Ragex.AI.Provider.OpenAI
  defp provider_module(:anthropic), do: Ragex.AI.Provider.Anthropic
  defp provider_module(:ollama), do: Ragex.AI.Provider.Ollama
  defp provider_module(_), do: Config.provider()
end
