defmodule Ragex.API.Auth do
  @moduledoc """
  Plug for optional API key authentication.

  When `RAGEX_API_KEY` environment variable is set, all requests must include
  a matching `Authorization: Bearer <key>` header. When the env var is unset,
  all requests pass through without authentication.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case System.get_env("RAGEX_API_KEY") do
      nil ->
        # No API key configured -- open access
        conn

      "" ->
        conn

      expected_key ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> provided_key] when provided_key == expected_key ->
            conn

          _ ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              401,
              :json.encode(%{error: "Unauthorized", message: "Invalid or missing API key"})
            )
            |> halt()
        end
    end
  end
end
