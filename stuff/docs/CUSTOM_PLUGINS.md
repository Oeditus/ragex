# Writing Custom Plugins for Ragex

Ragex features an **Extended Plugin Architecture** (`Ragex.Plugin` & `Ragex.Plugin.Registry`) that allows developers and teams to create custom MCP tools, code analyzers, and service integrations without modifying Ragex core files.

### Built-in Domain Plugins

Ragex comes pre-packaged with modular domain plugins:
- **`Ragex.Plugins.GraphAnalytics`**: Knowledge Graph entity lookup & centrality algorithms.
- **`Ragex.Plugins.GitArchaeology`**: Line-by-line git blame, history, PR details, and co-change coupling.
- **`Ragex.Plugins.CodeQuality`**: Code smell detection, dead code analysis, and duplication scanner.
- **`Ragex.Plugins.SecurityAudit`**: CWE security vulnerability scanner and secret checker.
- **`Ragex.Plugins.URLAnalyzer`**: URL analysis for remote Git repositories, web pages, and API specs.

---

## 🚀 Quick Start: Scaffolding a New Plugin

Ragex provides a built-in Mix task to generate plugin scaffolds and unit test files:

```bash
mix ragex.plugin SecurityAuditor --tool scan_vulnerabilities --description "Scans project files for custom security compliance rules"
```

### Generated Files

1. **Plugin Implementation**: `lib/ragex/plugins/security_auditor.ex`
2. **Unit Test File**: `test/ragex/plugins/security_auditor_test.exs`

---

## 📜 The `Ragex.Plugin` Behaviour Contract

All plugins implement the `@behaviour Ragex.Plugin` contract:

```elixir
defmodule MyCompany.Plugins.JiraIntegration do
  @behaviour Ragex.Plugin

  @doc """
  Returns plugin metadata.
  """
  @impl true
  def info do
    %{
      id: :jira_integration,
      name: "Jira Issue Tracker",
      version: "1.0.0",
      description: "Integrates Ragex with Jira to link code elements to active tickets.",
      author: "DevOps Team",
      category: :integration,
      dependencies: [],
      priority: 50,
      capabilities: [:jira_sync]
    }
  end

  @doc """
  Returns MCP tool schemas provided by this plugin.
  """
  @impl true
  def tools do
    [
      %{
        name: "get_jira_ticket",
        description: "Retrieves details for a Jira ticket by key.",
        inputSchema: %{
          type: "object",
          properties: %{
            ticket_key: %{
              type: "string",
              description: "Jira ticket ID (e.g. PROJ-1234)"
            }
          },
          required: ["ticket_key"]
        }
      }
    ]
  end

  @doc """
  Executes a tool call requested by an MCP client or AI agent.
  """
  @impl true
  def execute("get_jira_ticket", %{"ticket_key" => key} = _args) do
    # Fetch ticket info from your external API or internal service
    {:ok, %{ticket_key: key, status: "IN_PROGRESS", assignee: "alice@example.com"}}
  end

  def execute(tool_name, _args) do
    {:error, "Unknown tool '\#{tool_name}' for JiraIntegration plugin"}
  end

  @doc """
  Optional initialization callback invoked when the plugin is registered.
  """
  @impl true
  def init(opts) do
    # Perform startup configuration checks or service connections
    :ok
  end
end
```

---

## ⚙️ Plugin Registration & Configuration

Plugins can be registered automatically at application startup or dynamically at runtime.

### 1. Configuration (`config/config.exs`)

Add your plugin module to the `:plugins` list in your application configuration:

```elixir
config :ragex,
  plugins: [
    MyCompany.Plugins.JiraIntegration,
    MyCompany.Plugins.DockerScanner
  ]
```

### 2. Runtime Registration

Register plugins programmatically at any time:

```elixir
# Register plugin
:ok = Ragex.Plugin.Registry.register_plugin(MyCompany.Plugins.JiraIntegration)

# Unregister plugin
:ok = Ragex.Plugin.Registry.unregister_plugin(:jira_integration)
```

### 3. Hot Enabling & Disabling

Plugins can be enabled or disabled on the fly without restarting the server:

```elixir
# Disable plugin temporarily
Ragex.Plugin.Registry.disable_plugin(:jira_integration)

# Re-enable plugin
Ragex.Plugin.Registry.enable_plugin(:jira_integration)
```

---

## 📡 Listening for System Events (`handle_event/2`)

Plugins can subscribe to system lifecycle events by implementing the optional `handle_event/2` callback:

```elixir
defmodule MyCompany.Plugins.EventNotifier do
  @behaviour Ragex.Plugin

  @impl true
  def info do
    %{
      id: :event_notifier,
      name: "Event Notifier",
      version: "1.0.0",
      description: "Sends slack notifications on security alerts.",
      category: :integration,
      dependencies: [],
      priority: 90,
      capabilities: [:slack_notify]
    }
  end

  @impl true
  def tools, do: []

  @impl true
  def execute(_tool, _args), do: {:error, :no_tools}

  @impl true
  def handle_event(:security_alert, %{file: file, issue: issue}) do
    # React to security alert event
    Logger.warning("Security alert on \#{file}: \#{issue}")
    :ok
  end

  def handle_event(_event_name, _payload), do: :ok
end
```

Broadcasting events across plugins:

```elixir
Ragex.Plugin.EventBus.broadcast(:security_alert, %{file: "lib/app.ex", issue: "Hardcoded key"})
```

Custom plugins can leverage the full range of Ragex internal services:

### 1. Knowledge Graph Queries (`Ragex.Graph.Store`)

```elixir
# Query nodes or relationships
nodes = Ragex.Graph.Store.query_nodes(:function, %{module: "MyApp.Account"})
```

### 2. Directory Code Analysis (`Ragex.Analyzers.Directory`)

```elixir
# Execute AST code analysis on target directory
{:ok, summary} = Ragex.Analyzers.Directory.analyze_directory("/path/to/target")
```

### 3. AI Providers & Generation (`Ragex.AI.Provider.Registry`)

```elixir
# Call configured AI provider (Anthropic, OpenAI, Ollama, DeepSeek)
{:ok, provider} = Ragex.AI.Provider.Registry.get_provider()
{:ok, response} = provider.generate("Summarize code architecture", context)
```

---

## 🧪 Testing Your Plugin

Scaffolded plugins include ExUnit test templates out of the box. You can test your plugin isolated or via `Ragex.Plugin.Registry`:

```elixir
defmodule MyCompany.Plugins.JiraIntegrationTest do
  use ExUnit.Case, async: true

  alias MyCompany.Plugins.JiraIntegration
  alias Ragex.Plugin.Registry, as: PluginRegistry

  test "returns metadata and tool definitions" do
    info = JiraIntegration.info()
    assert info.id == :jira_integration

    tools = JiraIntegration.tools()
    assert hd(tools).name == "get_jira_ticket"
  end

  test "executes tool via plugin registry" do
    start_supervised!(PluginRegistry)
    PluginRegistry.register_plugin(JiraIntegration)

    assert {:ok, %{status: "IN_PROGRESS"}} =
             PluginRegistry.dispatch_tool("get_jira_ticket", %{"ticket_key" => "PROJ-123"})
  end
end
```

Run tests with:

```bash
mix test test/ragex/plugins/
```
