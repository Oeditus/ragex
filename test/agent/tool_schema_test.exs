defmodule Ragex.Agent.ToolSchemaTest do
  use ExUnit.Case, async: true

  alias Ragex.Agent.ToolSchema

  describe "to_openai_tools/0" do
    test "returns a list of tools" do
      tools = ToolSchema.to_openai_tools()

      assert match?([_ | _], tools)
    end

    test "each tool has correct OpenAI format" do
      tools = ToolSchema.to_openai_tools()

      for tool <- tools do
        assert %{type: "function", function: function} = tool
        assert is_map(function)
        assert Map.has_key?(function, :name)
        assert Map.has_key?(function, :description)
        assert Map.has_key?(function, :parameters)
        assert is_binary(function.name)
        assert is_binary(function.description)
        assert is_map(function.parameters)
      end
    end

    test "parameters have type field" do
      tools = ToolSchema.to_openai_tools()

      for tool <- tools do
        assert %{function: %{parameters: params}} = tool
        assert Map.has_key?(params, :type)
      end
    end
  end

  describe "to_anthropic_tools/0" do
    test "returns a list of tools" do
      tools = ToolSchema.to_anthropic_tools()

      assert match?([_ | _], tools)
    end

    test "each tool has correct Anthropic format" do
      tools = ToolSchema.to_anthropic_tools()

      for tool <- tools do
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert Map.has_key?(tool, :input_schema)
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
      end
    end
  end

  describe "agent_tools/1" do
    test "returns curated subset for OpenAI format" do
      tools = ToolSchema.agent_tools(:openai)

      assert match?([_ | _], tools)
      # Should be fewer than all tools
      all_tools = ToolSchema.to_openai_tools()
      assert length(tools) < length(all_tools)
    end

    test "returns curated subset for Anthropic format" do
      tools = ToolSchema.agent_tools(:anthropic)

      assert match?([_ | _], tools)
    end

    test "returns OpenAI format for deepseek_r1" do
      tools = ToolSchema.agent_tools(:deepseek_r1)

      assert is_list(tools)
      # DeepSeek uses OpenAI format
      for tool <- tools do
        assert Map.has_key?(tool, :type)
        assert tool.type == "function"
      end
    end

    test "default format is OpenAI" do
      tools_default = ToolSchema.agent_tools()
      tools_openai = ToolSchema.agent_tools(:openai)

      assert tools_default == tools_openai
    end

    test "includes expected analysis tools" do
      tool_names = ToolSchema.agent_tool_names()

      assert "analyze_file" in tool_names
      assert "analyze_directory" in tool_names
      assert "semantic_search" in tool_names
      assert "find_dead_code" in tool_names
      assert "scan_security" in tool_names
      assert "suggest_refactorings" in tool_names
    end
  end

  describe "agent_tool_names/0" do
    test "returns list of strings" do
      names = ToolSchema.agent_tool_names()

      assert is_list(names)
      assert Enum.all?(names, &is_binary/1)
    end

    test "contains expected tools" do
      names = ToolSchema.agent_tool_names()

      # Analysis tools
      assert "analyze_file" in names
      assert "query_graph" in names
      assert "hybrid_search" in names

      # Quality tools
      assert "analyze_quality" in names
      assert "find_complex_code" in names

      # Security tools
      assert "scan_security" in names
      assert "analyze_security_issues" in names
    end

    test "does not contain editing tools" do
      names = ToolSchema.agent_tool_names()

      # Editing tools should be excluded from agent tools
      refute "edit_file" in names
      refute "edit_files" in names
      refute "refactor_code" in names
    end
  end

  describe "tool_by_name/2" do
    test "returns tool in MCP format by default" do
      {:ok, tool} = ToolSchema.tool_by_name("analyze_file")

      assert Map.has_key?(tool, :name)
      assert Map.has_key?(tool, :description)
      assert Map.has_key?(tool, :inputSchema)
      assert tool.name == "analyze_file"
    end

    test "returns tool in OpenAI format" do
      {:ok, tool} = ToolSchema.tool_by_name("analyze_file", :openai)

      assert tool.type == "function"
      assert tool.function.name == "analyze_file"
    end

    test "returns tool in Anthropic format" do
      {:ok, tool} = ToolSchema.tool_by_name("analyze_file", :anthropic)

      assert tool.name == "analyze_file"
      assert Map.has_key?(tool, :input_schema)
    end

    test "returns error for unknown tool" do
      assert {:error, :not_found} = ToolSchema.tool_by_name("nonexistent_tool")
    end

    test "deepseek_r1 format same as openai" do
      {:ok, openai_tool} = ToolSchema.tool_by_name("semantic_search", :openai)
      {:ok, deepseek_tool} = ToolSchema.tool_by_name("semantic_search", :deepseek_r1)

      assert openai_tool == deepseek_tool
    end
  end

  describe "tools_by_names/2" do
    test "returns multiple tools" do
      names = ["analyze_file", "semantic_search", "find_dead_code"]
      tools = ToolSchema.tools_by_names(names)

      assert [_, _, _] = tools
    end

    test "skips unknown tools" do
      names = ["analyze_file", "nonexistent", "semantic_search"]
      tools = ToolSchema.tools_by_names(names)

      assert [_, _] = tools
      tool_names = Enum.map(tools, & &1.function.name)
      assert "analyze_file" in tool_names
      assert "semantic_search" in tool_names
    end

    test "returns empty list for all unknown" do
      names = ["nonexistent1", "nonexistent2"]
      tools = ToolSchema.tools_by_names(names)

      assert tools == []
    end
  end

  describe "tools_for_provider/2" do
    test "returns tools for deepseek_r1" do
      tools = ToolSchema.tools_for_provider(:deepseek_r1)

      assert match?([_ | _], tools)
      # DeepSeek uses OpenAI format
      for tool <- tools do
        assert tool.type == "function"
      end
    end

    test "returns tools for openai" do
      tools = ToolSchema.tools_for_provider(:openai)

      assert is_list(tools)

      for tool <- tools do
        assert tool.type == "function"
      end
    end

    test "returns tools for anthropic" do
      tools = ToolSchema.tools_for_provider(:anthropic)

      assert is_list(tools)

      for tool <- tools do
        assert Map.has_key?(tool, :input_schema)
        refute Map.has_key?(tool, :type)
      end
    end

    test "returns tools for ollama (uses OpenAI format)" do
      tools = ToolSchema.tools_for_provider(:ollama)

      assert is_list(tools)

      for tool <- tools do
        assert tool.type == "function"
      end
    end

    test "supports :only filter" do
      tools = ToolSchema.tools_for_provider(:openai, only: ["analyze_file", "query_graph"])

      assert [_, _] = tools
      names = Enum.map(tools, & &1.function.name)
      assert "analyze_file" in names
      assert "query_graph" in names
    end

    test "supports :except filter" do
      all_tools = ToolSchema.tools_for_provider(:openai)
      filtered_tools = ToolSchema.tools_for_provider(:openai, except: ["analyze_file"])

      assert length(filtered_tools) == length(all_tools) - 1
      names = Enum.map(filtered_tools, & &1.function.name)
      refute "analyze_file" in names
    end

    test "unknown provider defaults to OpenAI format" do
      tools = ToolSchema.tools_for_provider(:unknown_provider)

      assert is_list(tools)

      for tool <- tools do
        assert tool.type == "function"
      end
    end
  end
end
