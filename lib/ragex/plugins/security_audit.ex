defmodule Ragex.Plugins.SecurityAudit do
  @moduledoc """
  Plugin providing security scanning, CWE business logic checks, and secret exposure detection.
  """

  @behaviour Ragex.Plugin
  alias Ragex.Analysis.{BusinessLogic, Security}

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
        description: "Perform comprehensive security scanning on a file or project directory.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to file or directory"}
          },
          required: ["path"]
        }
      },
      %{
        name: "check_secrets",
        description: "Scan code files for hardcoded secrets, API keys, passwords, and tokens.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to file or directory"}
          },
          required: ["path"]
        }
      }
    ]
  end

  @impl true
  def execute("scan_security", %{"path" => path}) do
    case Security.analyze_file(path, []) do
      {:ok, result} -> {:ok, %{status: "success", security_findings: result}}
      {:error, reason} -> {:error, "Security scan failed: #{inspect(reason)}"}
    end
  end

  def execute("check_secrets", %{"path" => path}) do
    case BusinessLogic.analyze_file(path, []) do
      {:ok, result} -> {:ok, %{status: "success", secrets_findings: result}}
      {:error, reason} -> {:error, "Secret check failed: #{inspect(reason)}"}
    end
  end

  def execute(tool_name, _args) do
    {:error, "Unknown tool '#{tool_name}' for SecurityAudit plugin"}
  end
end
