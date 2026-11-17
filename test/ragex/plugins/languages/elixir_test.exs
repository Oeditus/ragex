defmodule Ragex.Plugins.Languages.ElixirTest do
  use ExUnit.Case, async: true

  alias Ragex.Plugins.Languages.Elixir, as: ElixirPlugin
  alias Ragex.Plugins.Languages.Elixir.Propwise

  describe "plugin contract" do
    test "declares :elixir as its only language" do
      assert ElixirPlugin.languages() == [:elixir]
      assert ElixirPlugin.info().language == :elixir
    end

    test "info/0 metadata is complete" do
      info = ElixirPlugin.info()

      assert info.id == :elixir_language
      assert info.category == :analyzer
      assert is_binary(info.version)
      assert is_binary(info.description)
    end

    test "tools/0 advertises propwise_analyze and muex_analyze" do
      assert [propwise, muex] = ElixirPlugin.tools()

      assert propwise.name == "propwise_analyze"
      assert propwise.destruction_level == :none
      assert propwise.inputSchema.required == ["path"]

      assert muex.name == "muex_analyze"
      assert muex.destruction_level == :none
      assert muex.inputSchema.required == ["path"]
    end

    test "every advertised tool has a dispatch clause" do
      # A tool advertised without a clause is a trap: the registry would offer
      # it and every call would fail with "Unknown tool". Bad-argument errors
      # are expected here (no real path is supplied) -- what must not happen is
      # the unknown-tool error.
      for %{name: name} <- ElixirPlugin.tools() do
        case ElixirPlugin.execute(name, %{}) do
          {:error, msg} -> refute msg =~ "Unknown tool", "#{name} has no dispatch clause"
          _ -> :ok
        end
      end
    end
  end

  describe "language scoping" do
    test "language_tools/1 returns tools only for :elixir" do
      assert [%{name: "propwise_analyze"}, %{name: "muex_analyze"}] =
               ElixirPlugin.language_tools(:elixir)

      assert ElixirPlugin.language_tools(:python) == []
      assert ElixirPlugin.language_tools(:ruby) == []
    end
  end

  describe "execute/2" do
    test "rejects unknown tools" do
      assert {:error, msg} = ElixirPlugin.execute("nope", %{})
      assert msg =~ "Unknown tool 'nope'"
    end

    test "propwise_analyze degrades cleanly when PropWise is absent" do
      # PropWise is not a Ragex dependency, so this is the shipped behaviour.
      unless Propwise.available?() do
        assert {:error, msg} = ElixirPlugin.execute("propwise_analyze", %{"path" => "."})
        assert msg =~ "PropWise is not available"
        assert msg =~ "mix.exs"
      end
    end

    test "muex_analyze validates its arguments" do
      # Muex, like PropWise, is not a Ragex dependency. The argument check runs
      # before any probe or subprocess, so it is the shipped behaviour either
      # way.
      assert {:error, msg} = ElixirPlugin.execute("muex_analyze", %{})
      assert msg =~ "requires a \"path\" argument"
    end

    test "muex_analyze reports a missing Mix project rather than a score" do
      assert {:error, msg} = ElixirPlugin.execute("muex_analyze", %{"path" => "/nonexistent"})
      assert msg =~ "no mix.exs"
    end
  end

  # The Elixir abstraction defects this plugin used to repair (`@moduledoc`
  # mistyped as a function call, raw AST leaking from type expressions) are
  # fixed in Metastatic itself, so the plugin no longer implements
  # `post_process/2`. These tests pin the upstream behaviour the plugin relies
  # on: if Metastatic regresses, they fail here rather than silently degrading
  # every Elixir analysis.
  describe "Metastatic Elixir abstraction (no repair needed)" do
    test "@moduledoc is an assignment, not a function call" do
      {:ok, doc} = parse(~s|defmodule M do\n  @moduledoc "hi"\n  def f, do: 1\nend|)

      refute "moduledoc" in function_call_names(doc.ast)
    end

    test "all doc-like attributes stay out of the call graph" do
      source = """
      defmodule M do
        @moduledoc "m"
        @behaviour GenServer
        @enforce_keys [:a]
        @typedoc "t"
        @doc "d"
        def f(x), do: x
      end
      """

      {:ok, doc} = parse(source)
      names = function_call_names(doc.ast)

      for attr <- ~w(moduledoc behaviour enforce_keys typedoc doc) do
        refute attr in names, "@#{attr} leaked as a function_call"
      end
    end

    test "type expressions do not leak raw Elixir AST into walks" do
      {:ok, doc} = parse("defmodule M do\n  @type t :: :a | :b\nend")

      types = doc.ast |> Metastatic.AST.postwalker() |> Enum.map(&elem(&1, 0))

      refute :| in types
      refute :"::" in types
    end

    test "unrelated function calls are untouched" do
      {:ok, doc} = parse("defmodule M do\n  def f(x), do: String.trim(x)\nend")

      assert "String.trim" in function_call_names(doc.ast)
    end
  end

  defp parse(source) do
    {:ok, ast} = Metastatic.quote(source, :elixir)
    {:ok, Metastatic.Document.new(ast, :elixir, %{}, source)}
  end

  defp function_call_names(ast) do
    for {:function_call, meta, _} <- Metastatic.AST.postwalker(ast),
        do: Keyword.get(meta, :name)
  end
end
