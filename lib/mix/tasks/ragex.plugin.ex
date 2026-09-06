defmodule Mix.Tasks.Ragex.Plugin do
  @moduledoc """
  Generates a scaffold for a new Ragex plugin and corresponding test file.

  ## Usage

      mix ragex.plugin NAME [options]

  ## Options

    * `--name NAME` - Name of the plugin module (e.g. JiraScanner, SecurityAudit)
    * `--tool TOOL_NAME` - Primary MCP tool name (defaults to snake_case of NAME)
    * `--description DESC` - Description of the plugin and tool
    * `--dir DIR` - Output directory for the plugin module (default: `lib/ragex/plugins`)
    * `--force` - Overwrite existing plugin files

  ## Examples

      # Generate plugin with default options
      mix ragex.plugin DockerScanner

      # Generate plugin with custom tool name and description
      mix ragex.plugin JiraIntegration --tool search_jira_issues --description "Queries Jira for open tickets"

      # Force overwrite existing plugin file
      mix ragex.plugin AuditTool --force
  """

  use Mix.Task

  @shortdoc "Scaffolds a new Ragex plugin and test file"

  @impl Mix.Task
  def run(args) do
    {opts, positional} =
      OptionParser.parse!(args,
        switches: [
          name: :string,
          tool: :string,
          description: :string,
          dir: :string,
          force: :boolean
        ],
        aliases: [
          n: :name,
          t: :tool,
          d: :description,
          f: :force
        ]
      )

    raw_name = opts[:name] || List.first(positional)

    if is_nil(raw_name) or String.trim(raw_name) == "" do
      Mix.raise("""
      Error: Plugin name is required.

      Usage: mix ragex.plugin NAME [options]
      Example: mix ragex.plugin SecurityAuditor
      """)
    end

    module_name = Macro.camelize(raw_name)
    snake_name = Macro.underscore(raw_name)
    tool_name = opts[:tool] || snake_name
    description = opts[:description] || "Custom Ragex plugin providing #{tool_name} functionality."
    force = Keyword.get(opts, :force, false)
    target_dir = opts[:dir] || "lib/ragex/plugins"
    test_dir = "test/ragex/plugins"

    module_file = Path.join(target_dir, "#{snake_name}.ex")
    test_file = Path.join(test_dir, "#{snake_name}_test.exs")

    create_file_safely(module_file, render_plugin_template(module_name, snake_name, tool_name, description), force)
    create_file_safely(test_file, render_test_template(module_name, snake_name, tool_name), force)

    Mix.shell().info("""

    ✨ Plugin scaffold created successfully!

    Files generated:
      - #{module_file}
      - #{test_file}

    Next Steps:
      1. Implement your tool logic in #{module_file}
      2. Run unit tests: mix test #{test_file}
      3. Register your plugin in config/config.exs:
         config :ragex, plugins: [Ragex.Plugins.#{module_name}]
    """)
  end

  defp create_file_safely(file_path, content, force) do
    if File.exists?(file_path) and not force do
      Mix.raise("File #{file_path} already exists. Use --force to overwrite.")
    else
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, content)
      Mix.shell().info("Created #{file_path}")
    end
  end

  defp render_plugin_template(module_name, snake_name, tool_name, description) do
    """
    defmodule Ragex.Plugins.#{module_name} do
      @moduledoc \"\"\"
      #{description}
      \"\"\"

      @behaviour Ragex.Plugin

      @impl true
      def info do
        %{
          id: :#{snake_name},
          name: "#{module_name}",
          version: "0.1.0",
          description: "#{description}"
        }
      end

      @impl true
      def tools do
        [
          %{
            name: "#{tool_name}",
            description: "#{description}",
            inputSchema: %{
              type: "object",
              properties: %{
                query: %{
                  type: "string",
                  description: "Input parameter for #{tool_name}"
                }
              },
              required: ["query"]
            }
          }
        ]
      end

      @impl true
      def execute("#{tool_name}", %{"query" => query} = _args) do
        # TODO: Implement custom tool logic here
        {:ok, %{status: "success", tool: "#{tool_name}", result: "Processed: \#{query}"}}
      end

      def execute(tool_name, _args) do
        {:error, "Unknown tool '\#{tool_name}' for plugin #{module_name}"}
      end
    end
    """
  end

  defp render_test_template(module_name, snake_name, tool_name) do
    """
    defmodule Ragex.Plugins.#{module_name}Test do
      use ExUnit.Case, async: true

      alias Ragex.Plugins.#{module_name}

      describe "#{module_name} Plugin" do
        test "info/0 returns valid metadata" do
          info = #{module_name}.info()
          assert info.id == :#{snake_name}
          assert info.name == "#{module_name}"
        end

        test "tools/0 returns tool definition" do
          tools = #{module_name}.tools()
          assert length(tools) == 1
          assert hd(tools).name == "#{tool_name}"
        end

        test "execute/2 runs tool successfully" do
          assert {:ok, %{status: "success"}} = #{module_name}.execute("#{tool_name}", %{"query" => "test"})
        end
      end
    end
    """
  end
end
