defmodule Ragex.API.RouterTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Ragex.API.Router

  @opts Router.init([])

  describe "GET /api/health" do
    test "returns 200 with status ok" do
      conn = conn(:get, "/api/health") |> Router.call(@opts)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert is_binary(body["version"])
    end
  end

  describe "GET /api/tools" do
    test "returns 200 with tool list" do
      conn = conn(:get, "/api/tools") |> Router.call(@opts)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["tools"])
      assert body["tools"] != []
    end

    test "each tool has name and description" do
      conn = conn(:get, "/api/tools") |> Router.call(@opts)
      body = Jason.decode!(conn.resp_body)

      Enum.each(body["tools"], fn tool ->
        assert is_binary(tool["name"])
        assert is_binary(tool["description"])
      end)
    end
  end

  describe "GET /api/openapi.json" do
    test "returns valid OpenAPI 3.0 spec" do
      conn = conn(:get, "/api/openapi.json") |> Router.call(@opts)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["openapi"] == "3.0.3"
      assert is_map(body["info"])
      assert is_map(body["paths"])
    end

    test "spec includes tool endpoints" do
      conn = conn(:get, "/api/openapi.json") |> Router.call(@opts)
      body = Jason.decode!(conn.resp_body)
      paths = body["paths"]
      assert Map.has_key?(paths, "/api/tools/analyze_file")
      assert Map.has_key?(paths, "/api/tools/semantic_search")
    end

    test "spec includes health endpoint" do
      conn = conn(:get, "/api/openapi.json") |> Router.call(@opts)
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body["paths"], "/api/health")
    end
  end

  describe "POST /api/tools/:tool_name" do
    test "returns 422 for unknown tool" do
      conn =
        conn(:post, "/api/tools/nonexistent_tool", %{})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Unknown tool"
    end

    test "returns 200 for graph_stats (no params needed)" do
      conn =
        conn(:post, "/api/tools/graph_stats", %{})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_integer(body["node_count"])
    end

    test "returns 200 for list_nodes" do
      conn =
        conn(:post, "/api/tools/list_nodes", %{"limit" => 5})
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["nodes"])
    end
  end

  describe "404 handling" do
    test "returns 404 for unknown routes" do
      conn = conn(:get, "/unknown/path") |> Router.call(@opts)
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Not found"
    end
  end
end
