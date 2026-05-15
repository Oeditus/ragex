defmodule Mix.Tasks.Ragex.Serve do
  @shortdoc "Start the Ragex REST API HTTP server"
  @moduledoc """
  Starts the Ragex REST API server on the specified port.

  ## Usage

      mix ragex.serve              # default port 4321
      mix ragex.serve --port 8080  # custom port

  The server exposes all MCP tools over HTTP:

  - `GET  /api/health`            -- health check
  - `GET  /api/tools`             -- list tools
  - `GET  /api/openapi.json`      -- OpenAPI spec
  - `POST /api/tools/:tool_name`  -- invoke a tool

  Set `RAGEX_API_KEY` to require authentication.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [port: :integer])

    port = Keyword.get(opts, :port, 4321)

    # Ensure the application is started (skip bumblebee in tasks to avoid GPU contention)
    Application.put_env(:ragex, :skip_bumblebee, true)
    Application.put_env(:ragex, :start_server, false)
    Application.put_env(:ragex, :start_stdio_server, false)
    Mix.Task.run("app.start")

    Mix.shell().info("Ragex REST API starting on http://localhost:#{port}")
    Mix.shell().info("OpenAPI spec: http://localhost:#{port}/api/openapi.json")
    Mix.shell().info("Press Ctrl+C to stop\n")

    alias Ragex.API.Server, as: APIServer
    {:ok, _pid} = APIServer.start_link(port: port)

    # Keep the task running
    Process.sleep(:infinity)
  end
end
