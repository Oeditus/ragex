defmodule Ragex.CLI.EditorConfig do
  @moduledoc """
  Editor configuration generator for AI code editors.

  Generates the correct MCP configuration file for each supported editor,
  pointing to the `ragex-mcp` binary. Respects existing config files by
  merging rather than overwriting.

  ## Supported Editors

  | Editor          | Config Path                  | Format    |
  |-----------------|------------------------------|-----------|
  | Claude Code     | `.mcp.json`                  | JSON      |
  | Cursor          | `.cursor/mcp.json`           | JSON      |
  | VS Code         | `.vscode/settings.json`      | JSON merge|
  | Zed             | `.zed/settings.json`         | JSON merge|
  | Gemini          | `.gemini/settings.json`      | JSON      |
  | NeoVim/LunarVim | `.nvim-mcp.json`             | JSON      |
  | OpenCode        | `.opencode.json`             | JSON      |
  | Warp            | (uses Warp's native MCP)     | --        |
  """

  require Logger

  @editors %{
    claude: %{
      name: "Claude Code",
      config_path: ".mcp.json",
      detect: [".mcp.json"],
      key: "mcpServers"
    },
    cursor: %{
      name: "Cursor",
      config_path: ".cursor/mcp.json",
      detect: [".cursor/", ".cursor/mcp.json"],
      key: "mcpServers"
    },
    vscode: %{
      name: "VS Code",
      config_path: ".vscode/settings.json",
      detect: [".vscode/", ".vscode/settings.json"],
      key: "mcp.servers"
    },
    zed: %{
      name: "Zed",
      config_path: ".zed/settings.json",
      detect: [".zed/", ".zed/settings.json"],
      key: "context_servers"
    },
    gemini: %{
      name: "Gemini CLI",
      config_path: ".gemini/settings.json",
      detect: [".gemini/"],
      key: "mcpServers"
    },
    neovim: %{
      name: "NeoVim / LunarVim",
      config_path: ".nvim-mcp.json",
      detect: [".nvim-mcp.json", "init.lua", ".luarc.json"],
      key: "mcpServers"
    },
    opencode: %{
      name: "OpenCode",
      config_path: ".opencode.json",
      detect: [".opencode.json"],
      key: "mcpServers"
    }
  }

  @doc "Returns info for all supported editors."
  @spec all_editors() :: map()
  def all_editors, do: @editors

  @doc """
  Detect which editors have config files present in the project directory.

  Returns a list of `{editor_key, editor_info}` tuples.
  """
  @spec detect_editors(String.t()) :: [{atom(), map()}]
  def detect_editors(project_dir) do
    Enum.filter(@editors, fn {_key, info} ->
      Enum.any?(info.detect, fn marker ->
        Path.join(project_dir, marker) |> File.exists?()
      end)
    end)
  end

  @doc """
  Generate and write the MCP config for a specific editor.

  ## Options
  - `:force` -- overwrite existing config (default `false`)
  - `:ragex_bin` -- path to ragex-mcp binary (auto-detected)
  - `:project_dir` -- project root (default: cwd)

  ## Returns
  `{:ok, path}` with the written config path, or `{:error, reason}`.
  """
  @spec generate(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(editor, project_dir, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    case Map.get(@editors, editor) do
      nil ->
        {:error, {:unknown_editor, editor}}

      info ->
        config_path = Path.join(project_dir, info.config_path)
        ragex_bin = Keyword.get(opts, :ragex_bin, find_ragex_bin(project_dir))

        cond do
          is_nil(ragex_bin) ->
            {:error, :ragex_bin_not_found}

          File.exists?(config_path) and not force ->
            merge_config(config_path, info, ragex_bin, project_dir)

          true ->
            write_fresh_config(config_path, info, ragex_bin, project_dir)
        end
    end
  end

  @doc """
  Generate configs for all detected editors in the project.

  Returns a map of `%{editor => {:ok, path} | {:error, reason}}`.
  """
  @spec generate_all(String.t(), keyword()) :: map()
  def generate_all(project_dir, opts \\ []) do
    detected = detect_editors(project_dir)

    if detected == [] do
      # No existing editor configs; generate for Claude Code as default
      %{claude: generate(:claude, project_dir, opts)}
    else
      Map.new(detected, fn {key, _info} ->
        {key, generate(key, project_dir, opts)}
      end)
    end
  end

  @doc "Returns a list of editor keys (atoms) for selection menus."
  @spec editor_choices() :: [{String.t(), atom()}]
  def editor_choices do
    Enum.map(@editors, fn {key, info} -> {info.name, key} end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  # ── Config generation ────────────────────────────────────────────────

  defp ragex_server_config(ragex_bin, project_dir) do
    %{
      "command" => ragex_bin,
      "args" => ["--project", project_dir],
      "env" => %{}
    }
  end

  defp write_fresh_config(config_path, info, ragex_bin, project_dir) do
    File.mkdir_p!(Path.dirname(config_path))

    config =
      case info.key do
        "mcp.servers" ->
          # VS Code nested key
          %{
            "mcp" => %{
              "servers" => %{
                "ragex" => %{"command" => ragex_bin, "args" => ["--project", project_dir]}
              }
            }
          }

        "context_servers" ->
          # Zed uses command.path structure
          %{
            "context_servers" => %{
              "ragex" => %{
                "command" => %{
                  "path" => ragex_bin,
                  "args" => ["--project", project_dir],
                  "env" => %{}
                }
              }
            }
          }

        _ ->
          %{info.key => %{"ragex" => ragex_server_config(ragex_bin, project_dir)}}
      end

    json = :json.encode(config) |> IO.iodata_to_binary()
    File.write!(config_path, json)
    Logger.info("Created #{config_path}")
    {:ok, config_path}
  end

  defp merge_config(config_path, info, ragex_bin, project_dir) do
    case File.read(config_path) do
      {:ok, content} ->
        existing =
          case :json.decode(content) do
            map when is_map(map) -> map
            _ -> %{}
          end

        merged =
          case info.key do
            "mcp.servers" ->
              servers = get_in(existing, ["mcp", "servers"]) || %{}

              updated_servers =
                Map.put(servers, "ragex", %{
                  "command" => ragex_bin,
                  "args" => ["--project", project_dir]
                })

              deep_put(existing, ["mcp", "servers"], updated_servers)

            "context_servers" ->
              servers = Map.get(existing, "context_servers", %{})

              updated =
                Map.put(servers, "ragex", %{
                  "command" => %{
                    "path" => ragex_bin,
                    "args" => ["--project", project_dir],
                    "env" => %{}
                  }
                })

              Map.put(existing, "context_servers", updated)

            key ->
              servers = Map.get(existing, key, %{})
              updated = Map.put(servers, "ragex", ragex_server_config(ragex_bin, project_dir))
              Map.put(existing, key, updated)
          end

        json = :json.encode(merged) |> IO.iodata_to_binary()
        File.write!(config_path, json)
        Logger.info("Merged ragex into #{config_path}")
        {:ok, config_path}

      {:error, _reason} ->
        # File exists but can't be read; write fresh
        write_fresh_config(config_path, info, ragex_bin, project_dir)
    end
  rescue
    _ -> write_fresh_config(config_path, info, ragex_bin, project_dir)
  end

  defp find_ragex_bin(project_dir) do
    candidates = [
      Path.join(project_dir, "bin/ragex-mcp"),
      Path.expand("bin/ragex-mcp"),
      System.find_executable("ragex-mcp")
    ]

    Enum.find(candidates, &(&1 && File.exists?(&1)))
  end

  # Deep put for nested string keys (avoids Kernel.put_in/3 conflict)
  defp deep_put(map, [key], value) do
    Map.put(map, key, value)
  end

  defp deep_put(map, [key | rest], value) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, deep_put(nested, rest, value))
  end
end
