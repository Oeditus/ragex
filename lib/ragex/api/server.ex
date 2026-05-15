defmodule Ragex.API.Server do
  @moduledoc """
  Lightweight HTTP server for the Ragex REST API bridge.

  Wraps `Bandit` with the `Ragex.API.Router` plug. Started optionally
  when `config :ragex, :start_api` is `true`, or manually via
  `mix ragex.serve`.

  ## Configuration

      config :ragex,
        start_api: true,
        api_port: 4321

  ## Manual Start

      Ragex.API.Server.start_link(port: 4321)
  """

  require Logger

  @default_port 4321

  @doc """
  Start the HTTP server.

  ## Options

  - `:port` -- TCP port (default: 4321, overridden by config or env)
  """
  def start_link(opts \\ []) do
    port =
      Keyword.get(opts, :port) ||
        Application.get_env(:ragex, :api_port, @default_port)

    Logger.info("Starting Ragex REST API on port #{port}")

    Bandit.start_link(
      plug: Ragex.API.Router,
      port: port,
      scheme: :http
    )
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end
end
