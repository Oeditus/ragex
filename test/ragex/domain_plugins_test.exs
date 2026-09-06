defmodule Ragex.DomainPluginsTest do
  use ExUnit.Case, async: true

  alias Ragex.Plugins.{CodeQuality, GitArchaeology, GraphAnalytics, SecurityAudit}

  describe "GitArchaeology Plugin" do
    test "info/0 and tools/0 return metadata and schemas" do
      info = GitArchaeology.info()
      assert info.id == :git_archaeology
      assert info.category == :git

      tools = GitArchaeology.tools()
      names = Enum.map(tools, & &1.name)
      assert "git_blame" in names
      assert "git_history" in names
      assert "co_change_analysis" in names
    end
  end

  describe "CodeQuality Plugin" do
    test "info/0 and tools/0 return metadata and schemas" do
      info = CodeQuality.info()
      assert info.id == :code_quality
      assert info.category == :analyzer

      tools = CodeQuality.tools()
      names = Enum.map(tools, & &1.name)
      assert "detect_smells" in names
      assert "find_dead_code" in names
      assert "find_duplicates" in names
    end
  end

  describe "SecurityAudit Plugin" do
    test "info/0 and tools/0 return metadata and schemas" do
      info = SecurityAudit.info()
      assert info.id == :security_audit
      assert info.category == :security

      tools = SecurityAudit.tools()
      names = Enum.map(tools, & &1.name)
      assert "scan_security" in names
      assert "check_secrets" in names
    end
  end

  describe "GraphAnalytics Plugin" do
    test "info/0 and tools/0 return metadata and schemas" do
      info = GraphAnalytics.info()
      assert info.id == :graph_analytics
      assert info.category == :analyzer

      tools = GraphAnalytics.tools()
      names = Enum.map(tools, & &1.name)
      assert "query_graph" in names
      assert "betweenness_centrality" in names
    end
  end
end
