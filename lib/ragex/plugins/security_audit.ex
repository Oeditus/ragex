defmodule Ragex.Plugins.SecurityAudit do
  @moduledoc """
  Plugin providing security scanning, CWE business logic checks, and secret exposure detection.
  """

  @behaviour Ragex.Plugin
  alias Ragex.MCP.Handlers.Tools

  @impl true
  def info do
    %{
      id: :security_audit,
      name: "Security Vulnerability & Compliance Audit",
      version: "1.0.0",
      description:
        "Scans project code for security vulnerabilities, exposed secrets, injection risks, and CWE patterns.",
      category: :security,
      dependencies: [],
      priority: 30,
      capabilities: [:security_scan, :secret_check, :cwe_audit]
    }
  end

  @impl true
  def tools do
    [
      %{
        name: "scan_security",
        description:
          "Scan source files for common vulnerability patterns: injection, unsafe deserialization, hardcoded secrets, weak crypto. Returns findings with file:line, severity, and CWE reference.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File or directory path to scan"},
            recursive: %{
              type: "boolean",
              description: "Recursively scan directories",
              default: true
            },
            min_severity: %{
              type: "string",
              description: "Minimum severity level to report",
              enum: ["low", "medium", "high", "critical"],
              default: "low"
            }
          },
          required: ["path"]
        }
      },
      %{
        name: "check_secrets",
        description:
          "Scan source files for hardcoded secrets: API keys, passwords, connection strings, tokens. Returns file:line locations with the matched pattern type.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File or directory path to scan"},
            recursive: %{
              type: "boolean",
              description: "Recursively scan directories",
              default: true
            }
          },
          required: ["path"]
        }
      }
    ]
  end

  # Delegates to the full-featured implementations in Ragex.MCP.Handlers.Tools
  # (proper Security-analyzer-backed directory/file handling, category and
  # severity filtering) rather than reimplementing a stripped-down subset
  # here -- notably, the prior version called BusinessLogic.analyze_file/2
  # for check_secrets instead of the Security analyzer, an unrelated module.
  # See the Ragex Codebase Health & Architecture Improvement Plan.
  @impl true
  def execute("scan_security", args), do: Tools.scan_security_tool(args)
  def execute("check_secrets", args), do: Tools.check_secrets_tool(args)

  def execute(tool_name, _args) do
    {:error, "Unknown tool '#{tool_name}' for SecurityAudit plugin"}
  end
end
