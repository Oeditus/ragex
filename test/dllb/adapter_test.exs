defmodule Ragex.Dllb.AdapterTest do
  use ExUnit.Case, async: true

  alias Ragex.Dllb.Adapter

  describe "enabled?/0" do
    test "returns false by default" do
      refute Adapter.enabled?()
    end
  end

  describe "query/1 (disabled)" do
    test "returns {:error, :dllb_disabled} when disabled" do
      assert {:error, :dllb_disabled} = Adapter.query("SELECT * FROM ast_node")
    end
  end

  describe "bootstrap/0 (disabled)" do
    test "returns {:error, :dllb_disabled} when disabled" do
      assert {:error, :dllb_disabled} = Adapter.bootstrap()
    end
  end

  describe "store_node/3 (disabled)" do
    test "returns :ok when disabled (no-op)" do
      assert :ok = Adapter.store_node(:module, MyModule, %{name: MyModule})
    end

    test "returns :ok for function nodes when disabled" do
      assert :ok =
               Adapter.store_node(:function, {MyModule, :parse, 2}, %{
                 name: :parse,
                 arity: 2
               })
    end
  end

  describe "store_edge/4 (disabled)" do
    test "returns :ok when disabled (no-op)" do
      assert :ok =
               Adapter.store_edge(
                 {:module, ModA},
                 {:module, ModB},
                 :imports
               )
    end

    test "returns :ok with metadata when disabled" do
      assert :ok =
               Adapter.store_edge(
                 {:function, {ModA, :a, 1}},
                 {:function, {ModB, :b, 0}},
                 :calls,
                 %{weight: 1.0}
               )
    end
  end

  describe "store_embedding/4 (disabled)" do
    test "returns :ok when disabled (no-op)" do
      assert :ok =
               Adapter.store_embedding(
                 :function,
                 {MyModule, :parse, 2},
                 [0.1, 0.2, 0.3],
                 "parse function"
               )
    end
  end

  describe "vector_search/2 (disabled)" do
    test "returns {:error, :dllb_disabled} when disabled" do
      assert {:error, :dllb_disabled} = Adapter.vector_search([0.1, 0.2, 0.3])
    end

    test "returns {:error, :dllb_disabled} with opts when disabled" do
      assert {:error, :dllb_disabled} =
               Adapter.vector_search([0.1, 0.2, 0.3], limit: 5, node_type: :function)
    end
  end
end
