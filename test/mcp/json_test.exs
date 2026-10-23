defmodule Ragex.MCP.JSONTest do
  use ExUnit.Case, async: true

  alias Ragex.MCP.JSON

  describe "result_to_json/1" do
    test "renders tuples as inspected strings" do
      assert JSON.result_to_json({:ok, 1}) == "{:ok, 1}"
    end

    test "converts nested lists and maps recursively" do
      input = %{items: [%{"nested" => {:tuple, 1}}, 2, "three"]}

      assert JSON.result_to_json(input) == %{
               items: [%{"nested" => "{:tuple, 1}"}, 2, "three"]
             }
    end

    test "keeps binary keys and stringifies other keys" do
      result = JSON.result_to_json(%{"binary" => 1, 3 => 4, atom: 2})

      assert result["binary"] == 1
      assert result[:atom] == 2
      assert result["3"] == 4
    end

    test "sanitizes invalid UTF-8 binaries" do
      assert JSON.result_to_json(<<0xFF, 0x41>>) == "\uFFFDA"
    end

    test "passes through scalars untouched" do
      assert JSON.result_to_json(nil) == nil
      assert JSON.result_to_json(42) == 42
      assert JSON.result_to_json(1.5) == 1.5
      assert JSON.result_to_json(:an_atom) == :an_atom
    end
  end

  describe "safe_json_encode/1" do
    test "encodes JSON-safe terms" do
      assert {:ok, json} = JSON.safe_json_encode(%{"a" => 1})
      assert json == ~s({"a":1})
    end
  end

  describe "encode_or_inspect/1" do
    test "encodes JSON-safe terms" do
      assert JSON.encode_or_inspect(%{"a" => [1, 2]}) == ~s({"a":[1,2]})
    end

    test "falls back to inspect for unencodable terms" do
      assert JSON.encode_or_inspect({:not, :json}) == "{:not, :json}"
    end
  end
end
