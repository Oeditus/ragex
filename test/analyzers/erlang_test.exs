defmodule Ragex.Analyzers.ErlangTest do
  use ExUnit.Case, async: true

  alias Ragex.Analyzers.Erlang, as: ErlangAnalyzer

  describe "analyze/2" do
    test "extracts module information" do
      source = """
      -module(test_module).
      -export([hello/0]).

      hello() -> world.
      """

      assert {:ok, result} = ErlangAnalyzer.analyze(source, "test_module.erl")
      assert [module] = result.modules
      assert module.name == :test_module
      assert module.file == "test_module.erl"
      assert module.line == 1
    end

    test "extracts function information with exports" do
      source = """
      -module(test_module).
      -export([public_func/2, another_public/0]).

      public_func(Arg1, Arg2) ->
          {ok, Arg1, Arg2}.

      another_public() ->
          ok.

      private_func() ->
          private.
      """

      assert {:ok, result} = ErlangAnalyzer.analyze(source, "test.erl")
      assert length(result.functions) == 3

      public_func = Enum.find(result.functions, &(&1.name == :public_func))
      assert public_func.arity == 2
      assert public_func.visibility == :public
      assert public_func.module == :test_module

      another_public = Enum.find(result.functions, &(&1.name == :another_public))
      assert another_public.arity == 0
      assert another_public.visibility == :public

      private_func = Enum.find(result.functions, &(&1.name == :private_func))
      assert private_func.arity == 0
      assert private_func.visibility == :private
    end

    test "extracts import information" do
      source = """
      -module(test_module).
      -import(lists, [map/2, filter/2]).
      -import(string, [concat/2]).

      test() -> ok.
      """

      assert {:ok, result} = ErlangAnalyzer.analyze(source, "test.erl")
      assert length(result.imports) == 2

      assert Enum.any?(result.imports, &(&1.to_module == :lists && &1.type == :import))
      assert Enum.any?(result.imports, &(&1.to_module == :string && &1.type == :import))
    end

    test "extracts remote function calls" do
      source = """
      -module(test_module).
      -export([caller/0]).

      caller() ->
          lists:map(fun(X) -> X * 2 end, [1, 2, 3]),
          io:format("Hello~n", []).
      """

      assert {:ok, result} = ErlangAnalyzer.analyze(source, "test.erl")
      assert length(result.calls) >= 2

      lists_call = Enum.find(result.calls, &(&1.to_module == :lists && &1.to_function == :map))
      assert lists_call.from_function == :caller
      assert lists_call.from_arity == 0

      io_call = Enum.find(result.calls, &(&1.to_module == :io && &1.to_function == :format))
      assert io_call.from_function == :caller
    end

    test "extracts local function calls" do
      source = """
      -module(test_module).
      -export([caller/0]).

      caller() ->
          helper().

      helper() ->
          ok.
      """

      assert {:ok, result} = ErlangAnalyzer.analyze(source, "test.erl")

      local_call =
        Enum.find(result.calls, &(&1.to_function == :helper && &1.to_module == :test_module))

      assert local_call.from_function == :caller
      assert local_call.from_arity == 0
    end

    test "handles syntax errors gracefully" do
      source = """
      -module(broken_module).

      broken_func( ->
          error.
      """

      # Should return partial results or error
      result = ErlangAnalyzer.analyze(source, "broken.erl")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles case expressions with calls" do
      source = """
      -module(test_module).
      -export([test/1]).

      test(Value) ->
          case Value of
              ok -> lists:reverse([1, 2, 3]);
              error -> io:format("Error~n")
          end.
      """

      assert {:ok, result} = ErlangAnalyzer.analyze(source, "test.erl")

      assert Enum.any?(result.calls, &(&1.to_module == :lists && &1.to_function == :reverse))
      assert Enum.any?(result.calls, &(&1.to_module == :io && &1.to_function == :format))
    end
  end

  describe "supported_extensions/0" do
    test "returns erlang file extensions" do
      assert [".erl", ".hrl"] = ErlangAnalyzer.supported_extensions()
    end
  end
end
