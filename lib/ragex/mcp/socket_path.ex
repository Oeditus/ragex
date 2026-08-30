defmodule Ragex.MCP.SocketPath do
  @moduledoc """
  Resolves the Unix domain socket path used by the MCP socket server and its
  clients (bin/ragex-mcp, bin/ragex-bridge, Ragex.MCP.Client, editor plugins).

  Running `ragex` "in the wild" means several independent instances may be
  active on the same machine at once -- one per project, or one per `dllb`
  backend port. A single hardcoded `/tmp/ragex_mcp.sock` causes one instance
  to steal the socket file out from under another, or causes a client to
  bridge into the wrong server entirely.

  To avoid that, the path is namespaced using this precedence:

    1. `RAGEX_MCP_SOCK` -- explicit override, used verbatim. Mirrors dllb's
       own `DLLB_SOCK` escape hatch.
    2. `DLLB_PORT` -- if set, this instance is tied to a specific `dllb`
       server port, so the socket is namespaced by that port:
       `ragex_mcp_<port>.sock`.
    3. Otherwise, namespaced by the identity of the project being served:
       `RAGEX_PROJECT`, then `RAGEX_AUTO_ANALYZE`, then the current working
       directory, sanitized into `ragex_mcp_<sanitized_path>.sock`.

  Bash callers (bin/ragex-mcp) must implement the exact same precedence so
  that a launcher script and the BEAM VM it starts always agree on the
  socket path.
  """

  @default_dir "/tmp"

  @doc "Resolves the socket path as a charlist, ready for :gen_tcp :local addresses."
  @spec compute() :: charlist()
  def compute do
    compute_string() |> to_charlist()
  end

  @doc "Resolves the socket path as a binary string."
  @spec compute_string() :: String.t()
  def compute_string do
    case env("RAGEX_MCP_SOCK") do
      nil -> default_path()
      sock -> sock
    end
  end

  defp default_path do
    case env("DLLB_PORT") do
      nil -> Path.join(@default_dir, "ragex_mcp_#{sanitize(identity())}.sock")
      port -> Path.join(@default_dir, "ragex_mcp_#{port}.sock")
    end
  end

  defp identity do
    env("RAGEX_PROJECT") || env("RAGEX_AUTO_ANALYZE") || File.cwd!()
  end

  defp sanitize(path) do
    path
    |> Path.expand()
    |> String.trim_leading("/")
    |> String.replace(~r/[^A-Za-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end
end
