defmodule Ragex.API.OpenAPI do
  @moduledoc """
  Generates an OpenAPI 3.0 specification from the MCP tool definitions.

  The spec is generated lazily from `Tools.list_tools()` and cached in
  a persistent term for fast subsequent access.

  Served at `GET /api/openapi.json`.
  """

  alias Ragex.MCP.Handlers.Tools

  @doc """
  Generate the full OpenAPI 3.0 specification.

  Each MCP tool becomes a `POST /api/tools/{tool_name}` endpoint with the
  tool's `inputSchema` as the request body schema.
  """
  @spec generate() :: map()
  def generate do
    case :persistent_term.get({__MODULE__, :spec}, nil) do
      nil ->
        spec = build_spec()
        :persistent_term.put({__MODULE__, :spec}, spec)
        spec

      cached ->
        cached
    end
  end

  @doc """
  Clear the cached spec (useful after tool definitions change).
  """
  def clear_cache do
    :persistent_term.erase({__MODULE__, :spec})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Private

  defp build_spec do
    %{tools: tools} = Tools.list_tools()

    paths =
      Enum.into(tools, %{}, fn tool ->
        path = "/api/tools/#{tool.name}"

        operation = %{
          "summary" => tool.description,
          "operationId" => tool.name,
          "tags" => [categorize_tool(tool.name)],
          "requestBody" => %{
            "required" => true,
            "content" => %{
              "application/json" => %{
                "schema" => convert_schema(tool.inputSchema)
              }
            }
          },
          "responses" => %{
            "200" => %{
              "description" => "Successful tool invocation",
              "content" => %{
                "application/json" => %{
                  "schema" => %{"type" => "object"}
                }
              }
            },
            "422" => %{
              "description" => "Tool execution error",
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{
                      "error" => %{"type" => "string"}
                    }
                  }
                }
              }
            }
          }
        }

        {path, %{"post" => operation}}
      end)

    # Add non-tool endpoints
    extra_paths = %{
      "/api/health" => %{
        "get" => %{
          "summary" => "Health check",
          "operationId" => "health",
          "tags" => ["system"],
          "responses" => %{
            "200" => %{
              "description" => "Server is healthy",
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{
                      "status" => %{"type" => "string"},
                      "version" => %{"type" => "string"}
                    }
                  }
                }
              }
            }
          }
        }
      },
      "/api/tools" => %{
        "get" => %{
          "summary" => "List all available MCP tools",
          "operationId" => "listTools",
          "tags" => ["system"],
          "responses" => %{
            "200" => %{
              "description" => "Tool catalogue",
              "content" => %{
                "application/json" => %{
                  "schema" => %{"type" => "object"}
                }
              }
            }
          }
        }
      }
    }

    %{
      "openapi" => "3.0.3",
      "info" => %{
        "title" => "Ragex REST API",
        "description" =>
          "HTTP bridge to Ragex MCP tools for non-MCP integrations (CI, dashboards, scripts)",
        "version" => to_string(Application.spec(:ragex, :vsn) || "0.0.0")
      },
      "servers" => [
        %{"url" => "http://localhost:4321", "description" => "Local development"}
      ],
      "security" => [%{"bearerAuth" => []}],
      "components" => %{
        "securitySchemes" => %{
          "bearerAuth" => %{
            "type" => "http",
            "scheme" => "bearer",
            "description" => "API key via RAGEX_API_KEY env var (optional)"
          }
        }
      },
      "paths" => Map.merge(extra_paths, paths)
    }
  end

  defp convert_schema(schema) when is_map(schema) do
    schema
    |> Enum.into(%{}, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), convert_schema(v)}
      {k, v} -> {k, convert_schema(v)}
    end)
  end

  defp convert_schema(value) when is_list(value), do: Enum.map(value, &convert_schema/1)

  defp convert_schema(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp convert_schema(value), do: value

  defp categorize_tool(name) do
    cond do
      String.starts_with?(name, "analyze_") or name in ~w[list_nodes query_graph] -> "analysis"
      String.starts_with?(name, "find_") -> "search"
      String.starts_with?(name, "git_") or name == "co_change_analysis" -> "git"
      String.starts_with?(name, "edit_") or String.contains?(name, "refactor") -> "editing"
      String.starts_with?(name, "rag_") -> "rag"
      String.starts_with?(name, "agent_") -> "agent"
      String.starts_with?(name, "mcp_") -> "telemetry"
      String.starts_with?(name, "scip_") -> "scip"
      name in ~w[semantic_search hybrid_search search_strings expand_query] -> "search"
      name in ~w[scan_security security_audit check_secrets] -> "security"
      true -> "other"
    end
  end
end
