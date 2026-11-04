defmodule Ragex.Analyzers.Elixir.MacroExpanderTest do
  use ExUnit.Case, async: true

  alias Ragex.Analyzers.Elixir.MacroExpander

  defp parse!(source) do
    {:ok, ast} = Code.string_to_quoted(source, columns: true)
    ast
  end

  describe "expand/3 with :none" do
    test "returns the AST untouched" do
      ast = parse!("data |> Repo.insert()")
      assert MacroExpander.expand(ast, :none) == ast
    end
  end

  describe "expand/3 with :partial" do
    test "desugars the pipe operator into a direct call" do
      expanded = MacroExpander.expand(parse!("data |> Repo.insert()"), :partial)

      assert {{:., _, [Repo, :insert]}, _, [{:data, _, nil}]} = expanded
    end

    test "preserves defmodule and def structure" do
      expanded = MacroExpander.expand(parse!("defmodule S do\n  def f(x), do: x\nend"), :partial)

      assert {:defmodule, _, [_, [do: {:def, _, _}]]} = expanded
    end

    test "expands use for a module already loaded in the runtime" do
      expanded = MacroExpander.expand(parse!("defmodule S do\n  use GenServer\nend"), :partial)

      refute Macro.to_string(expanded) =~ "@unexpanded"
      assert Macro.to_string(expanded) =~ "child_spec"
    end

    test "never raises on an unresolvable macro" do
      expanded =
        MacroExpander.expand(parse!("defmodule S do\n  use No.Such.Module\nend"), :partial)

      assert is_tuple(expanded)
    end
  end

  describe "unexpanded/1" do
    test "returns an empty list when everything resolves" do
      expanded = MacroExpander.expand(parse!("defmodule S do\n  def f, do: :ok\nend"), :partial)

      assert MacroExpander.unexpanded(expanded) == []
    end

    test "reports the reason a macro could not be expanded" do
      expanded =
        MacroExpander.expand(parse!("defmodule S do\n  use No.Such.Module\nend"), :partial)

      assert [reason] = MacroExpander.unexpanded(expanded)
      assert reason =~ "No.Such.Module"
    end

    test "is empty for an unexpanded :none AST" do
      assert MacroExpander.unexpanded(parse!("defmodule S do\n  use GenServer\nend")) == []
    end
  end

  describe "strip_markers/1" do
    test "removes @unexpanded markers from the AST" do
      expanded =
        MacroExpander.expand(parse!("defmodule S do\n  use No.Such.Module\nend"), :partial)

      stripped = MacroExpander.strip_markers(expanded)

      refute Macro.to_string(stripped) =~ "@unexpanded"
      # The original `use` survives, just without the diagnostic
      assert Macro.to_string(stripped) =~ "use No.Such.Module"
    end
  end

  describe "use_targets/1" do
    test "collects aliased use targets" do
      ast = parse!("defmodule S do\n  use GenServer\n  use Foo.Bar, opt: 1\nend")

      assert MacroExpander.use_targets(ast) == [GenServer, Foo.Bar]
    end

    test "returns an empty list when there are no use directives" do
      assert MacroExpander.use_targets(parse!("defmodule S do\n  def f, do: :ok\nend")) == []
    end

    test "deduplicates repeated use directives" do
      ast = parse!("defmodule S do\n  use GenServer\n  use GenServer\nend")

      assert MacroExpander.use_targets(ast) == [GenServer]
    end
  end
end
