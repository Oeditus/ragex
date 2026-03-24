defmodule Ragex.Analysis.Suggestions.Ranker do
  @moduledoc """
  Priority ranking system for refactoring suggestions.

  Scores suggestions based on multiple factors:
  - **Benefit** (40%): Expected improvement from refactoring
  - **Impact** (20%): Scope of change (number of affected files/modules)
  - **Risk** (20%): Likelihood of introducing bugs (subtracted)
  - **Effort** (10%): Time/complexity to implement (subtracted)
  - **Confidence** (10%): Confidence in the detection

  ## Priority Levels

  - **critical** (score > 0.8): Must address soon, high impact issues
  - **high** (score > 0.6): Important improvements with good ROI
  - **medium** (score > 0.4): Beneficial but not urgent
  - **low** (score > 0.2): Optional improvements
  - **info** (score <= 0.2): For awareness only

  ## Examples

      alias Ragex.Analysis.Suggestions.Ranker

      suggestion = %{
        pattern: :extract_function,
        confidence: 0.85,
        benefit_score: 0.8,
        effort_score: 0.5,
        impact: %{affected_files: 3, risk: :medium}
      }

      scored = Ranker.score_suggestion(suggestion)
      # => %{...suggestion, priority: :high, priority_score: 0.72}
  """

  @benefit_weight 0.4
  @impact_weight 0.2
  @risk_weight 0.2
  @effort_weight 0.1
  @confidence_weight 0.1

  @risk_scores %{
    low: 0.2,
    medium: 0.5,
    high: 0.8,
    critical: 1.0
  }

  @doc """
  Scores a suggestion and assigns a priority level.

  ## Parameters
  - `suggestion` - Raw suggestion map from pattern detector

  ## Returns
  - Suggestion with added `:priority` and `:priority_score` fields
  """
  def score_suggestion(suggestion) do
    benefit = normalize_score(suggestion[:benefit_score] || 0.5)
    confidence = normalize_score(suggestion[:confidence] || 0.5)
    effort = normalize_score(suggestion[:effort_score] || 0.5)

    impact_score = calculate_impact_score(suggestion[:impact])
    risk_score = extract_risk_score(suggestion[:impact])

    priority_score =
      benefit * @benefit_weight +
        impact_score * @impact_weight -
        risk_score * @risk_weight -
        effort * @effort_weight +
        confidence * @confidence_weight

    # Clamp to [0, 1] range
    priority_score = max(0.0, min(1.0, priority_score))
    priority_score = Float.round(priority_score, 2)

    priority_level = classify_priority(priority_score)

    suggestion
    |> Map.put(:priority_score, priority_score)
    |> Map.put(:priority, priority_level)
  end

  @doc """
  Classifies a numeric priority score into a priority level.

  ## Examples

      iex> Ranker.classify_priority(0.85)
      :critical

      iex> Ranker.classify_priority(0.65)
      :high

      iex> Ranker.classify_priority(0.15)
      :info
  """
  def classify_priority(score) when score > 0.8, do: :critical
  def classify_priority(score) when score > 0.6, do: :high
  def classify_priority(score) when score > 0.4, do: :medium
  def classify_priority(score) when score > 0.2, do: :low
  def classify_priority(_score), do: :info

  @doc """
  Calculates ROI (Return on Investment) for a suggestion.

  ROI = Benefit / Effort

  Higher ROI means better return for the effort invested.
  """
  def calculate_roi(suggestion) do
    benefit = normalize_score(suggestion[:benefit_score] || 0.5)
    effort = normalize_score(suggestion[:effort_score] || 0.5)

    # Avoid division by zero
    effort = max(effort, 0.1)

    Float.round(benefit / effort, 2)
  end

  @doc """
  Compares two suggestions for sorting.

  Returns:
  - `:gt` if first has higher priority
  - `:lt` if second has higher priority
  - `:eq` if equal priority
  """
  def compare_priority(sugg1, sugg2) do
    score1 = sugg1[:priority_score] || 0.0
    score2 = sugg2[:priority_score] || 0.0

    cond do
      score1 > score2 -> :gt
      score1 < score2 -> :lt
      true -> :eq
    end
  end

  # Private functions

  defp normalize_score(score) when is_number(score) do
    max(0.0, min(1.0, score))
  end

  defp normalize_score(_), do: 0.5

  defp calculate_impact_score(impact) when is_map(impact) do
    affected_files = impact[:affected_files] || 1

    # More affected files = higher impact (but with diminishing returns)
    # Use logarithmic scale to prevent huge numbers from dominating
    base_impact = :math.log(affected_files + 1) / :math.log(10 + 1)

    # Cap at 1.0
    Float.round(min(base_impact, 1.0), 2)
  end

  defp calculate_impact_score(_), do: 0.3

  defp extract_risk_score(impact) when is_map(impact) do
    risk_level = impact[:risk] || :medium
    Map.get(@risk_scores, risk_level, 0.5)
  end

  defp extract_risk_score(_), do: 0.5

  @doc """
  Generates a human-readable explanation of the scoring.

  ## Examples

      explanation = Ranker.explain_score(suggestion)
      IO.puts(explanation)
  """
  def explain_score(suggestion) do
    benefit = normalize_score(suggestion[:benefit_score] || 0.5)
    confidence = normalize_score(suggestion[:confidence] || 0.5)
    effort = normalize_score(suggestion[:effort_score] || 0.5)
    impact_score = calculate_impact_score(suggestion[:impact])
    risk_score = extract_risk_score(suggestion[:impact])

    """
    Priority Score Breakdown:
    - Benefit: #{Float.round(benefit, 2)} × #{@benefit_weight} = #{Float.round(benefit * @benefit_weight, 2)}
    - Impact: #{Float.round(impact_score, 2)} × #{@impact_weight} = #{Float.round(impact_score * @impact_weight, 2)}
    - Risk: #{Float.round(risk_score, 2)} × #{@risk_weight} = -#{Float.round(risk_score * @risk_weight, 2)}
    - Effort: #{Float.round(effort, 2)} × #{@effort_weight} = -#{Float.round(effort * @effort_weight, 2)}
    - Confidence: #{Float.round(confidence, 2)} × #{@confidence_weight} = #{Float.round(confidence * @confidence_weight, 2)}

    Total Score: #{suggestion[:priority_score]}
    Priority Level: #{suggestion[:priority]}
    ROI: #{calculate_roi(suggestion)}
    """
  end

  @doc """
  Adjusts priority score based on pattern-specific factors.

  Some patterns are inherently more important:
  - Dead code removal: Low risk, easy win
  - Complexity reduction: High benefit
  - Coupling reduction: Medium-high effort, high benefit
  """
  def adjust_for_pattern(suggestion) do
    pattern = suggestion[:pattern]
    base_score = suggestion[:priority_score] || 0.5

    adjustment =
      case pattern do
        # Boost dead code removal (easy wins)
        :remove_dead_code -> 0.1
        # Slight boost for complexity
        :simplify_complexity -> 0.05
        # No adjustment
        :reduce_coupling -> 0.0
        # Slight penalty (high effort)
        :split_module -> -0.05
        _ -> 0.0
      end

    adjusted_score = max(0.0, min(1.0, base_score + adjustment))
    adjusted_score = Float.round(adjusted_score, 2)

    new_priority = classify_priority(adjusted_score)

    suggestion
    |> Map.put(:priority_score, adjusted_score)
    |> Map.put(:priority, new_priority)
  end

  @doc """
  Filters suggestions by minimum priority level.

  ## Examples

      suggestions
      |> Ranker.filter_by_priority(:high)
      # Returns only :critical and :high priority suggestions
  """
  def filter_by_priority(suggestions, min_priority) do
    priority_order = [:info, :low, :medium, :high, :critical]
    min_index = Enum.find_index(priority_order, &(&1 == min_priority)) || 0

    Enum.filter(suggestions, fn sugg ->
      sugg_index = Enum.find_index(priority_order, &(&1 == sugg.priority)) || 0
      sugg_index >= min_index
    end)
  end

  @doc """
  Groups suggestions by priority level.

  ## Returns
  Map with priority levels as keys and lists of suggestions as values.
  """
  def group_by_priority(suggestions) do
    suggestions
    |> Enum.group_by(& &1.priority)
  end

  @doc """
  Calculates statistics for a list of suggestions.

  Returns map with:
  - `:total` - Total number of suggestions
  - `:by_priority` - Count by priority level
  - `:average_score` - Average priority score
  - `:average_roi` - Average ROI
  - `:high_priority_count` - Count of high + critical
  """
  def calculate_statistics(suggestions) do
    by_priority =
      suggestions
      |> Enum.group_by(& &1.priority)
      |> Enum.map(fn {priority, list} -> {priority, length(list)} end)
      |> Enum.into(%{})

    average_score =
      case suggestions do
        [_ | _] ->
          total = Enum.reduce(suggestions, 0.0, fn s, acc -> acc + (s.priority_score || 0.0) end)
          Float.round(total / length(suggestions), 2)

        _ ->
          0.0
      end

    average_roi =
      case suggestions do
        [_ | _] ->
          total = Enum.reduce(suggestions, 0.0, fn s, acc -> acc + calculate_roi(s) end)
          Float.round(total / length(suggestions), 2)

        _ ->
          0.0
      end

    high_priority_count =
      Map.get(by_priority, :critical, 0) + Map.get(by_priority, :high, 0)

    %{
      total: length(suggestions),
      by_priority: by_priority,
      average_score: average_score,
      average_roi: average_roi,
      high_priority_count: high_priority_count
    }
  end
end
