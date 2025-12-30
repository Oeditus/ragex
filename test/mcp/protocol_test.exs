defmodule Ragex.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Ragex.MCP.Protocol

  describe "decode/1" do
    test "decodes valid JSON-RPC 2.0 request" do
      json = ~s({"jsonrpc":"2.0","method":"test","id":1})
      assert {:ok, %{"jsonrpc" => "2.0", "method" => "test", "id" => 1}} = Protocol.decode(json)
    end

    test "decodes notification without id" do
      json = ~s({"jsonrpc":"2.0","method":"notification"})
      assert {:ok, %{"jsonrpc" => "2.0", "method" => "notification"}} = Protocol.decode(json)
    end

    test "rejects invalid JSON-RPC version" do
      json = ~s({"jsonrpc":"1.0","method":"test","id":1})
      assert {:error, :invalid_jsonrpc_version} = Protocol.decode(json)
    end

    test "rejects invalid JSON" do
      json = "not json"
      assert {:error, {:parse_error, _}} = Protocol.decode(json)
    end
  end

  describe "encode/1" do
    test "encodes response message" do
      response = Protocol.success_response(%{data: "test"}, 1)
      assert {:ok, json} = Protocol.encode(response)
      assert json =~ ~s("jsonrpc":"2.0")
      assert json =~ ~s("result")
      assert json =~ ~s("id":1)
    end

    test "encodes error response" do
      response = Protocol.error_response(-32_600, "Invalid request", nil, 1)
      assert {:ok, json} = Protocol.encode(response)
      assert json =~ ~s("error")
      assert json =~ ~s("code":-32600)
    end
  end

  describe "success_response/2" do
    test "creates valid success response" do
      response = Protocol.success_response(%{test: "data"}, 42)
      assert %{jsonrpc: "2.0", result: %{test: "data"}, id: 42} = response
    end
  end

  describe "error_response/4" do
    test "creates error response with data" do
      response = Protocol.error_response(-32_600, "Test error", %{info: "test"}, 1)

      assert %{
               jsonrpc: "2.0",
               error: %{code: -32_600, message: "Test error", data: %{info: "test"}},
               id: 1
             } = response
    end

    test "creates error response without data" do
      response = Protocol.error_response(-32_600, "Test error", nil, 1)
      assert %{jsonrpc: "2.0", error: %{code: -32_600, message: "Test error"}, id: 1} = response
      refute Map.has_key?(response.error, :data)
    end
  end

  describe "request?/1" do
    test "returns true for messages with id" do
      assert Protocol.request?(%{"id" => 1})
      assert Protocol.request?(%{"id" => "test"})
    end

    test "returns false for messages without id" do
      refute Protocol.request?(%{})
      refute Protocol.request?(%{"method" => "test"})
    end
  end

  describe "notification?/1" do
    test "returns true for messages without id" do
      assert Protocol.notification?(%{})
      assert Protocol.notification?(%{"method" => "test"})
    end

    test "returns false for messages with id" do
      refute Protocol.notification?(%{"id" => 1})
    end
  end
end
