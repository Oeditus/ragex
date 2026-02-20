defmodule Ragex.Agent.ToolSchema do
  @moduledoc """
  Converts MCP tool definitions to AI provider tool formats.

  Supports:
  - OpenAI function calling format (also used by DeepSeek R1)
  - Anthropic tool use format

  ## Usage

      # Get all tools in OpenAI format
      tools = ToolSchema.to_openai_tools()

      # Get curated agent tools
      tools = ToolSchema.agent_tools(:openai)

      # Lookup specific tool
      {:ok, tool} = ToolSchema.tool_by_name("semantic_search")
  """

  alias Ragex.MCP.Handlers.Tools, as: MCPTools

  # Curated list of tool names useful for agent operations.
  # These are the tools the agent can use during autonomous analysis.
  # Excludes tools that could be dangerous or are not useful for analysis.
  @agent_tool_names [
    # Analysis tools
    "analyze_file",
    "analyze_directory",
    "query_graph",
    "list_nodes",
    "semantic_search",
    "hybrid_search",

    # Quality & issues
    "analyze_quality",
    "quality_report",
    "find_complex_code",
    "find_dead_code",
    "analyze_dead_code_patterns",
    "find_duplicates",
    "find_similar_code",
    "detect_smells",
    "scan_security",
    "security_audit",
    "analyze_security_issues",

    # Dependencies
    "analyze_dependencies",
    "find_circular_dependencies",
    "coupling_report",

    # Impact & suggestions
    "analyze_impact",
    "estimate_refactoring_effort",
    "risk_assessment",
    "suggest_refactorings",
    "explain_suggestion",

    # Business logic & semantic
    "analyze_business_logic",
    "semantic_operations",
    "semantic_analysis",

    # Graph algorithms
    "find_paths",
    "find_callers",
    "graph_stats",
    "betweenness_centrality",
    "closeness_centrality",
    "detect_communities"
  ]

  @doc """
  Get all MCP tools converted to OpenAI function calling format.

  This format is also compatible with DeepSeek R1.

  ## Returns

  List of tool definitions in OpenAI format:
  ```
  [
    %{
      type: "function",
      function: %{
        name: "tool_name",
        description: "Tool description",
        parameters: %{...json_schema...}
      }
    }
  ]
  ```
  """
  @spec to_openai_tools() :: [map()]
  def to_openai_tools do
    %{tools: mcp_tools} = MCPTools.list_tools()
    Enum.map(mcp_tools, &mcp_to_openai/1)
  end

  @doc """
  Get all MCP tools converted to Anthropic tool format.

  ## Returns

  List of tool definitions in Anthropic format:
  ```
  [
    %{
      name: "tool_name",
      description: "Tool description",
      input_schema: %{...json_schema...}
    }
  ]
  ```
  """
  @spec to_anthropic_tools() :: [map()]
  def to_anthropic_tools do
    %{tools: mcp_tools} = MCPTools.list_tools()
    Enum.map(mcp_tools, &mcp_to_anthropic/1)
  end

  @doc """
  Get curated subset of tools for agent use.

  ## Parameters

  - `format` - Output format: `:openai` (default, also for DeepSeek) or `:anthropic`

  ## Returns

  List of tool definitions in the requested format.
  """
  @spec agent_tools(atom()) :: [map()]
  def agent_tools(format \\ :openai)

  def agent_tools(:openai) do
    %{tools: mcp_tools} = MCPTools.list_tools()

    mcp_tools
    |> Enum.filter(&(&1.name in @agent_tool_names))
    |> Enum.map(&mcp_to_openai/1)
  end

  def agent_tools(:anthropic) do
    %{tools: mcp_tools} = MCPTools.list_tools()

    mcp_tools
    |> Enum.filter(&(&1.name in @agent_tool_names))
    |> Enum.map(&mcp_to_anthropic/1)
  end

  def agent_tools(:deepseek_r1), do: agent_tools(:openai)

  @doc """
  Get list of agent tool names.
  """
  @spec agent_tool_names() :: [String.t()]
  def agent_tool_names, do: @agent_tool_names

  @doc """
  Lookup a tool definition by name.

  ## Parameters

  - `name` - Tool name as string
  - `format` - Output format: `:openai`, `:anthropic`, or `:mcp` (default)

  ## Returns

  - `{:ok, tool}` - Tool definition in requested format
  - `{:error, :not_found}` - Tool not found
  """
  @spec tool_by_name(String.t(), atom()) :: {:ok, map()} | {:error, :not_found}
  def tool_by_name(name, format \\ :mcp)

  def tool_by_name(name, :mcp) do
    %{tools: mcp_tools} = MCPTools.list_tools()

    case Enum.find(mcp_tools, &(&1.name == name)) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  def tool_by_name(name, :openai) do
    case tool_by_name(name, :mcp) do
      {:ok, tool} -> {:ok, mcp_to_openai(tool)}
      error -> error
    end
  end

  def tool_by_name(name, :anthropic) do
    case tool_by_name(name, :mcp) do
      {:ok, tool} -> {:ok, mcp_to_anthropic(tool)}
      error -> error
    end
  end

  def tool_by_name(name, :deepseek_r1), do: tool_by_name(name, :openai)

  @doc """
  Convert a list of tool names to their definitions.

  ## Parameters

  - `names` - List of tool names
  - `format` - Output format

  ## Returns

  List of tool definitions (skips unknown tools).
  """
  @spec tools_by_names([String.t()], atom()) :: [map()]
  def tools_by_names(names, format \\ :openai) do
    names
    |> Enum.map(&tool_by_name(&1, format))
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, tool} -> tool end)
  end

  @doc """
  Get tools for a specific provider by name.

  ## Parameters

  - `provider` - Provider atom: `:deepseek_r1`, `:openai`, `:anthropic`, `:ollama`
  - `opts` - Options:
    - `:only` - List of tool names to include (default: all agent tools)
    - `:except` - List of tool names to exclude

  ## Returns

  List of tool definitions in the appropriate format for the provider.
  """
  @spec tools_for_provider(atom(), keyword()) :: [map()]
  def tools_for_provider(provider, opts \\ [])

  def tools_for_provider(provider, opts) when provider in [:deepseek_r1, :openai, :ollama] do
    get_filtered_tools(:openai, opts)
  end

  def tools_for_provider(:anthropic, opts) do
    get_filtered_tools(:anthropic, opts)
  end

  def tools_for_provider(_provider, opts) do
    # Default to OpenAI format for unknown providers
    get_filtered_tools(:openai, opts)
  end

  # Private functions

  defp get_filtered_tools(format, opts) do
    only = Keyword.get(opts, :only)
    except = Keyword.get(opts, :except, [])

    base_names = if only, do: only, else: @agent_tool_names

    filtered_names =
      base_names
      |> Enum.filter(&(&1 not in except))

    tools_by_names(filtered_names, format)
  end

  defp mcp_to_openai(%{name: name, description: description, inputSchema: schema}) do
    %{
      type: "function",
      function: %{
        name: name,
        description: description,
        parameters: normalize_schema(schema)
      }
    }
  end

  defp mcp_to_anthropic(%{name: name, description: description, inputSchema: schema}) do
    %{
      name: name,
      description: description,
      input_schema: normalize_schema(schema)
    }
  end

  # Normalize schema - ensure it's properly formatted JSON Schema
  defp normalize_schema(schema) when is_map(schema) do
    schema
    |> ensure_type()
    |> normalize_properties()
  end

  defp ensure_type(%{type: _} = schema), do: schema
  defp ensure_type(schema), do: Map.put(schema, :type, "object")

  defp normalize_properties(%{properties: props} = schema) when is_map(props) do
    normalized_props =
      props
      |> Enum.map(fn {k, v} -> {k, normalize_property(v)} end)
      |> Enum.into(%{})

    %{schema | properties: normalized_props}
  end

  defp normalize_properties(schema), do: schema

  defp normalize_property(%{type: "array", items: items} = prop) do
    %{prop | items: normalize_property(items)}
  end

  defp normalize_property(%{type: "object", properties: props} = prop) when is_map(props) do
    normalized_props =
      props
      |> Enum.map(fn {k, v} -> {k, normalize_property(v)} end)
      |> Enum.into(%{})

    %{prop | properties: normalized_props}
  end

  defp normalize_property(prop), do: prop
end
