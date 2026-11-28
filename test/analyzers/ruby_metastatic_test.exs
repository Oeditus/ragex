defmodule Ragex.Analyzers.RubyMetastaticTest do
  @moduledoc """
  Locks in Ragex's contract with the Metastatic Ruby provider.

  Metastatic 0.44 ("sharpen the Ruby provider") changed the shape of Ruby
  MetaAST in ways Ragex depends on, so these tests assert the *adapter*
  behaviour Ragex reads from -- not Ragex's own extraction, which is covered by
  `Ragex.Analyzers.MetaASTExtractorTest`.

  Each assertion corresponds to a specific 0.44 change:

    * a qualified call carries its receiver in `:receiver` instead of
      flattening it into `:name` (which rendered as the literal `"obj"`)
    * `:name` remains a plain string for existing callers
    * a singleton definition carries `:receiver`, so `def Foo.bar` reifies
    * `case/when`, `begin/rescue/ensure` and module mixins gained the
      `FromMeta` clauses they were missing, so they round-trip at all
    * `:ensure` lives on the node's own meta so it survives a statement list
    * keyword splats hold transformed children rather than a raw M1 map
    * unknown operator/method names are no longer interned as atoms

  These shell out to the `parser`/`unparser` gems, so they skip without Ruby.
  """

  use ExUnit.Case, async: true

  alias Metastatic.Adapters.Ruby

  @moduletag :ruby

  setup do
    if System.find_executable("ruby") do
      :ok
    else
      {:ok, skip: true}
    end
  end

  # Source -> M1 -> M2 -> M1 -> Source, returning the regenerated source.
  defp round_trip(source) do
    with {:ok, ast} <- Ruby.parse(source),
         {:ok, meta_ast, metadata} <- Ruby.to_meta(ast),
         {:ok, native} <- Ruby.from_meta(meta_ast, metadata) do
      Ruby.unparse(native)
    end
  end

  describe "qualified call receivers" do
    test "the receiver travels in the :receiver meta key" do
      {:ok, ast} = Ruby.parse("User.find_by(id: 1)")
      assert {:ok, {:function_call, meta, _args}, _} = Ruby.to_meta(ast)

      assert Keyword.get(meta, :name) == "User.find_by"

      assert {:literal, receiver_meta, "User"} = Keyword.get(meta, :receiver)
      assert Keyword.get(receiver_meta, :subtype) == :constant
    end

    test ":name stays a plain string for existing callers" do
      {:ok, ast} = Ruby.parse("a.b.c")
      assert {:ok, {:function_call, meta, _}, _} = Ruby.to_meta(ast)
      assert is_binary(Keyword.get(meta, :name))
    end

    test "a receiver the adapter cannot render no longer becomes \"obj\"" do
      # Before 0.44 this reified as `obj.find_by(...)`, silently moving the
      # call to a different object.
      assert {:ok, out} = round_trip("User.find_by(id: 1)")
      assert out =~ "User.find_by"
      refute out =~ "obj."
    end

    for {label, source, expected} <- [
          {"constant, no args", "Foo.bar", "Foo.bar"},
          {"namespaced constant", "Foo::Bar.new", "Foo::Bar.new"},
          {"self receiver", "self.foo(1)", "self.foo"},
          {"instance variable receiver", "@x.foo", "@x.foo"},
          {"chained calls", "a.b.c", "a.b.c"},
          {"local variable receiver", "x.foo", "x.foo"},
          {"safe navigation", "x&.y(1)", "x&.y"}
        ] do
      test "preserves the receiver of a #{label}" do
        assert {:ok, out} = round_trip(unquote(source))
        assert out =~ unquote(expected)
        refute out =~ "obj."
      end
    end

    test "reifies singleton method definitions on any receiver" do
      assert {:ok, out} = round_trip("def Foo.bar; 1; end")
      assert out =~ "def Foo.bar"
    end
  end

  describe "constructs that previously could not be reified" do
    test "case/when" do
      assert {:ok, out} = round_trip("case y when 1 then 2 else 3 end")
      assert out =~ "case y"
      assert out =~ "when 1"
      assert out =~ "else"
    end

    test "rescue with a class and a bound variable" do
      assert {:ok, out} = round_trip("begin; 1; rescue E => e; 2; end")
      assert out =~ "rescue E => e"
    end

    test "rescue with ensure" do
      assert {:ok, out} = round_trip("begin; 1; rescue E => e; 2; ensure; 3; end")
      assert out =~ "rescue E => e"
      assert out =~ "ensure"
    end

    test "ensure without rescue" do
      assert {:ok, out} = round_trip("begin; 1; ensure; 2; end")
      assert out =~ "ensure"
    end

    test "module mixins reify as import directives" do
      for mixin <- ["include", "prepend", "extend"] do
        assert {:ok, out} = round_trip("#{mixin} Foo")
        assert out =~ mixin
        assert out =~ "Foo"
      end
    end
  end

  describe "the :ensure body survives a statement list" do
    # `transform_list/1` discards child metadata, so an `ensure` body kept in
    # the returned metadata map was lost as soon as the node sat in a list.
    # 0.44 stores it on the node's own meta instead.
    test "ensure is carried on the node's own meta" do
      source = "begin; 1; rescue E => e; 2; ensure; cleanup; end"

      {:ok, ast} = Ruby.parse(source)
      assert {:ok, {:exception_handling, node_meta, _}, _metadata} = Ruby.to_meta(ast)
      assert Keyword.get(node_meta, :ensure) != nil
    end
  end

  describe "keyword splats" do
    test "hold transformed children rather than a raw M1 map" do
      # The previous shape stored the raw M1 node, which made the payload
      # opaque to analyzers and crashed JSON encoding on the way back out.
      assert {:ok, out} = round_trip("foo(**o)")
      assert out =~ "**o"
    end
  end

  describe "atom safety" do
    test "known operators become atoms" do
      assert {:ok, {:binary_op, meta, _}, _} =
               Ruby.to_meta(%{
                 "type" => "send",
                 "children" => [
                   %{"type" => "int", "children" => [1]},
                   "+",
                   %{"type" => "int", "children" => [2]}
                 ]
               })

      assert Keyword.get(meta, :operator) == :+
    end

    test "unknown method names are not interned as atoms" do
      # Ruby permits arbitrary method names, so `String.to_atom/1` on a
      # parser-supplied name let untrusted input grow the atom table.
      assert {:ok, meta_ast, _} =
               Ruby.to_meta(%{
                 "type" => "send",
                 "children" => [
                   %{"type" => "int", "children" => [1]},
                   "some_custom_operator",
                   %{"type" => "int", "children" => [2]}
                 ]
               })

      assert {:function_call, meta, _args} = meta_ast
      assert Keyword.get(meta, :name) =~ "some_custom_operator"
    end
  end

  describe "literals" do
    test "symbol literals stay symbols" do
      # JSON has no symbol type, so the bridge used to hand Unparser a string
      # and every symbol literal silently became a string literal.
      assert {:ok, out} = round_trip("x = :foo")
      assert out =~ ":foo"
      refute out =~ ~s("foo")
    end
  end
end
