defmodule Ragex.API.Router do
  @moduledoc """
  HTTP router for the Ragex REST API bridge.

  Exposes MCP tools over HTTP for non-MCP integrations (CI pipelines,
  dashboards, scripts, custom tooling).

  ## Endpoints

  - `GET  /api/health`          -- server health check
  - `GET  /api/tools`           -- list all available MCP tools
  - `GET  /api/openapi.json`    -- OpenAPI 3.0 specification
  - `POST /api/tools/:tool_name` -- invoke an MCP tool with JSON body

  ## Authentication

  When `RAGEX_API_KEY` is set, all requests require
  `Authorization: Bearer <key>`. Unset = open access.

  ## Usage

  Started via `mix ragex.serve` or programmatically:

      Ragex.API.Server.start_link(port: 4321)
  """

  use Plug.Router

  alias Ragex.API.OpenAPI
  alias Ragex.Graph.Store
  alias Ragex.MCP.Handlers.Tools
  alias Ragex.MCP.Telemetry, as: MCPTelemetry

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(Ragex.API.Auth)
  plug(:dispatch)

  # Health check
  get "/api/health" do
    stats = Store.stats()

    body =
      :json.encode(%{
        status: "ok",
        version: to_string(Application.spec(:ragex, :vsn) || "0.0.0"),
        graph: stats
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # List available tools
  get "/api/tools" do
    result = Tools.list_tools()
    body = Jason.encode!(result)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # OpenAPI specification
  get "/api/openapi.json" do
    spec = OpenAPI.generate()
    body = Jason.encode!(spec)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # Invoke a tool
  post "/api/tools/:tool_name" do
    arguments = conn.body_params || %{}

    case MCPTelemetry.execute(tool_name, fn -> Tools.call_tool(tool_name, arguments) end) do
      {:ok, result} ->
        body = result |> json_safe() |> Jason.encode!()

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} when is_binary(reason) ->
        body = Jason.encode!(%{error: reason})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(422, body)

      {:error, reason} when is_map(reason) ->
        body = reason |> json_safe() |> Jason.encode!()

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(422, body)

      {:error, reason} ->
        body = Jason.encode!(%{error: inspect(reason)})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, body)
    end
  end

  # Catch-all
  match _ do
    body = Jason.encode!(%{error: "Not found", path: conn.request_path})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, body)
  end

  # Convert Elixir terms to JSON-safe structures
  defp json_safe(value) when is_map(value) do
    Enum.into(value, %{}, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, json_safe(v)}
    end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()

  defp json_safe(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp json_safe(value) when is_pid(value), do: inspect(value)
  defp json_safe(value) when is_reference(value), do: inspect(value)
  defp json_safe(value), do: value
end
