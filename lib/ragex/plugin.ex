defmodule Ragex.Plugin do
  @moduledoc """
  Defines the behavior for Ragex extensions and plugins.

  Plugins allow adding custom MCP tools, analyzers, integrations, and services
  to Ragex without modifying core source files.

  ## Example

      defmodule MyCustomPlugin do
        @behaviour Ragex.Plugin

        @impl true
        def info do
          %{
            id: :my_plugin,
            name: "My Custom Plugin",
            version: "1.0.0",
            description: "Provides custom project tools.",
            category: :tool,
            dependencies: [],
            priority: 50,
            capabilities: [:custom_tools]
          }
        end

        @impl true
        def tools do
          [
            %{
              name: "custom_ping",
              description: "Returns a ping response.",
              inputSchema: %{
                type: "object",
                properties: %{}
              },
              destruction_level: :none
            }
          ]
        end

        @impl true
        def execute("custom_ping", _args) do
          {:ok, %{status: "pong"}}
        end
      end
  """

  @type destruction_level :: :none | :low | :medium | :high | :full

  @type tool_schema :: %{
          name: String.t(),
          description: String.t(),
          inputSchema: map(),
          destruction_level: destruction_level()
        }

  @type plugin_category ::
          :analyzer | :editor | :security | :search | :ai_provider | :git | :integration | :tool

  @type plugin_info :: %{
          id: atom(),
          name: String.t(),
          version: String.t(),
          description: String.t(),
          author: String.t() | nil,
          category: plugin_category(),
          dependencies: [atom()],
          priority: integer(),
          capabilities: [atom()]
        }

  @doc "Returns metadata describing the plugin."
  @callback info() :: plugin_info()

  @doc "Returns the list of MCP tool definitions provided by this plugin."
  @callback tools() :: [tool_schema()]

  @doc "Executes a tool call provided by this plugin."
  @callback execute(tool_name :: String.t(), args :: map()) ::
              {:ok, result :: map()} | {:error, reason :: term()}

  @doc "Optional initialization hook called when registering the plugin."
  @callback init(opts :: keyword()) :: :ok | {:error, term()}

  @doc "Optional event callback invoked when system events are broadcast."
  @callback handle_event(event_name :: atom(), payload :: map()) :: :ok | term()

  @optional_callbacks [init: 1, handle_event: 2]
end
