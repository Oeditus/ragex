defmodule Ragex.MCP.DelegateTest do
  use ExUnit.Case, async: true

  alias Ragex.MCP.{Client, Delegate}

  describe "atomize_keys/1" do
    test "converts string keys to atoms in flat map" do
      assert %{foo: 1, bar: 2} = Delegate.atomize_keys(%{"foo" => 1, "bar" => 2})
    end

    test "converts string keys recursively in nested maps" do
      input = %{"outer" => %{"inner" => 42}}
      assert %{outer: %{inner: 42}} = Delegate.atomize_keys(input)
    end

    test "converts string keys in lists of maps" do
      input = [%{"a" => 1}, %{"b" => 2}]
      assert [%{a: 1}, %{b: 2}] = Delegate.atomize_keys(input)
    end

    test "preserves atom keys" do
      input = %{"string_key" => 2, already_atom: 1}
      result = Delegate.atomize_keys(input)
      assert result.already_atom == 1
      assert result.string_key == 2
    end

    test "handles deeply nested structures" do
      input = %{
        "analyze_result" => %{
          "files_analyzed" => 10,
          "entities_found" => 50,
          "errors" => []
        },
        "results" => %{
          "security" => %{
            "issues" => [
              %{"severity" => "high", "file" => "lib/foo.ex"}
            ]
          }
        }
      }

      result = Delegate.atomize_keys(input)
      assert result.analyze_result.files_analyzed == 10
      assert [%{severity: "high", file: "lib/foo.ex"}] = result.results.security.issues
    end

    test "passes through non-map non-list values" do
      assert Delegate.atomize_keys(42) == 42
      assert Delegate.atomize_keys("hello") == "hello"
      assert Delegate.atomize_keys(nil) == nil
      assert Delegate.atomize_keys(true) == true
    end

    test "handles empty structures" do
      assert Delegate.atomize_keys(%{}) == %{}
      assert Delegate.atomize_keys([]) == []
    end
  end

  describe "atomize_values/2" do
    test "converts specified string values to atoms" do
      input = %{severity: "high", count: 3, type: "warning"}
      result = Delegate.atomize_values(input, [:severity, :type])
      assert result.severity == :high
      assert result.type == :warning
      assert result.count == 3
    end

    test "ignores non-string values in specified fields" do
      input = %{severity: :already_atom, count: 3}
      result = Delegate.atomize_values(input, [:severity, :count])
      assert result.severity == :already_atom
      assert result.count == 3
    end

    test "ignores missing fields" do
      input = %{foo: "bar"}
      result = Delegate.atomize_values(input, [:missing, :also_missing])
      assert result == %{foo: "bar"}
    end
  end

  describe "to_module_atom/1" do
    test "returns atoms unchanged" do
      assert Delegate.to_module_atom(Ragex.Graph.Store) == Ragex.Graph.Store
    end

    test "converts Elixir-prefixed strings" do
      assert Delegate.to_module_atom("Elixir.Ragex.Graph.Store") == Ragex.Graph.Store
    end

    test "converts capitalized module name strings" do
      assert Delegate.to_module_atom("Ragex.Graph.Store") == Ragex.Graph.Store
    end

    test "converts simple module names" do
      assert Delegate.to_module_atom("MyModule") == MyModule
    end

    test "converts lowercase strings as plain atoms" do
      assert Delegate.to_module_atom("some_key") == :some_key
    end
  end

  describe "with_server/1" do
    test "connects when server is running, errors when not" do
      result = Delegate.with_server(fn _conn -> :delegated end)

      if Client.server_running?() do
        assert {:ok, :delegated} = result
      else
        assert {:error, :not_running} = result
      end
    end

    test "returns callback error on exception" do
      if Client.server_running?() do
        assert {:error, {:callback_error, _msg}} =
                 Delegate.with_server(fn _conn -> raise "boom" end)
      end
    end
  end

  describe "server_available?/0" do
    test "returns boolean" do
      # Result depends on whether the app started the socket server
      assert is_boolean(Delegate.server_available?())
    end
  end
end
