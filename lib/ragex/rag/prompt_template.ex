defmodule Ragex.RAG.PromptTemplate do
  @moduledoc """
  Manages prompt engineering templates.

  Supports both text and structured JSON prompt formats.
  When `:response_format` is `:json`, templates instruct the model
  to consume JSON context and produce JSON output.
  """

  @doc """
  Render a prompt template.

  ## Parameters

  - `template` - Template name (`:query`, `:explain`, `:suggest`)
  - `vars` - Map with template variables

  ## Template Variables

  - `:system_prompt` - System instructions
  - `:context` - Retrieved code context (string)
  - `:query` - User query
  - `:response_format` - Optional, `:json` for structured output
  """
  def render(:query, %{response_format: :json} = vars) do
    """
    #{vars.system_prompt}

    # Code Context (JSON)

    #{vars.context}

    # User Query

    #{vars.query}

    Respond with valid JSON matching the schema described in the system prompt.
    Do not include any text outside the JSON object.
    """
  end

  def render(:query, vars) do
    """
    #{vars.system_prompt}

    # Code Context

    #{vars.context}

    # User Query

    #{vars.query}

    Please provide a detailed answer based on the code context above.
    Include specific references to files and functions when relevant.
    """
  end

  def render(:explain, %{response_format: :json} = vars) do
    """
    Explain the following code context provided as JSON.
    Respond with valid JSON matching this schema:
    {"explanation": "string", "key_concepts": ["string"], "dependencies": ["string"], "issues": ["string"]}

    #{vars.context}

    Focus on: #{vars.aspect}
    """
  end

  def render(:explain, vars) do
    """
    Explain the following code in detail:

    #{vars.context}

    Focus on: #{vars.aspect}
    """
  end

  def render(:suggest, %{response_format: :json} = vars) do
    """
    Review the following code context provided as JSON and suggest improvements.
    Respond with valid JSON matching this schema:
    {"suggestions": [{"type": "string", "target": "string", "description": "string", "priority": "high|medium|low"}]}

    #{vars.context}

    Focus area: #{vars.focus}
    """
  end

  def render(:suggest, vars) do
    """
    Review the following code and suggest improvements:

    #{vars.context}

    Focus area: #{vars.focus}

    Provide specific, actionable recommendations.
    """
  end
end
