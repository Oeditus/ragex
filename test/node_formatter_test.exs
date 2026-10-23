defmodule Ragex.NodeFormatterTest do
  use ExUnit.Case, async: true

  alias Ragex.NodeFormatter

  describe "format_node_id/2 with :mcp style (default)" do
    test "renders atoms with the Elixir prefix so clients can round-trip them" do
      assert NodeFormatter.format_node_id(MyApp.Foo) == "Elixir.MyApp.Foo"
    end

    test "renders {module, name, arity} function references" do
      assert NodeFormatter.format_node_id({MyApp.Foo, :bar, 2}) == "Elixir.MyApp.Foo.bar/2"
    end

    test "renders tagged {:module, id} tuples" do
      assert NodeFormatter.format_node_id({:module, MyApp.Foo}) == "module:Elixir.MyApp.Foo"
    end

    test "renders tagged {:function, module, name, arity} tuples" do
      assert NodeFormatter.format_node_id({:function, MyApp.Foo, :bar, 2}) ==
               "Elixir.MyApp.Foo.bar/2"
    end

    test "passes binaries through unchanged" do
      assert NodeFormatter.format_node_id("already/a/string") == "already/a/string"
    end

    test "falls back to inspect for unexpected shapes" do
      assert NodeFormatter.format_node_id(%{weird: :map}) == "%{weird: :map}"
    end

    test "inspects nil rather than returning nil" do
      assert NodeFormatter.format_node_id(nil) == "nil"
    end
  end

  describe "format_node_id/2 with :prompt style" do
    test "drops the Elixir prefix for readability in prose" do
      assert NodeFormatter.format_node_id(MyApp.Foo, :prompt) == "MyApp.Foo"
    end

    test "renders function references without the Elixir prefix" do
      assert NodeFormatter.format_node_id({MyApp.Foo, :bar, 2}, :prompt) == "MyApp.Foo.bar/2"
    end

    test "preserves nil so callers can substitute a default" do
      assert NodeFormatter.format_node_id(nil, :prompt) == nil
    end
  end

  test "both styles agree on tagged and untagged function references" do
    untagged = {MyApp.Foo, :bar, 2}
    tagged = {:function, MyApp.Foo, :bar, 2}

    for style <- [:mcp, :prompt] do
      assert NodeFormatter.format_node_id(untagged, style) ==
               NodeFormatter.format_node_id(tagged, style)
    end
  end
end
