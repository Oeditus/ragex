defmodule Ragex.Plugins.PrismaTest do
  use ExUnit.Case, async: true

  alias Ragex.Plugins.Prisma

  describe "plugin contract" do
    test "info/0 metadata is complete" do
      info = Prisma.info()

      assert info.id == :prisma
      assert info.category == :analyzer
      assert info.dependencies == []
      assert is_binary(info.version)
      assert is_binary(info.description)
    end

    test "tools/0 advertises prisma_analyze" do
      assert [schema] = Prisma.tools()

      assert schema.name == "prisma_analyze"
      assert schema.destruction_level == :none
      assert schema.inputSchema.properties.path.default == "."
    end

    test "the schema documents the mode and oxbow switches" do
      properties = Prisma.tools() |> hd() |> get_in([:inputSchema, :properties])

      for key <- [:path, :mode, :format, :include_oxbow] do
        assert Map.has_key?(properties, key), "expected #{key} to be documented"
      end

      assert properties.mode.enum == ["hybrid", "gradual", "discrepancy"]
    end

    test "every advertised tool has a dispatch clause" do
      # A tool advertised without a clause is a trap: the registry would offer
      # it and every call would fail with "Unknown tool". A non-string `path`
      # is rejected before any analysis runs.
      for %{name: name} <- Prisma.tools() do
        case Prisma.execute(name, %{"path" => 123}) do
          {:error, msg} -> refute msg =~ "Unknown tool", "#{name} has no dispatch clause"
          _ -> :ok
        end
      end
    end
  end

  describe "language scoping" do
    test "serves only the languages Prisma can analyze" do
      # Prisma reads compiled beams, so it is meaningless for Python or Ruby.
      assert Prisma.languages() == [:elixir, :erlang]
    end

    test "language_tools/1 returns the tool for a served language" do
      assert [%{name: "prisma_analyze"}] = Prisma.language_tools(:elixir)
      assert [%{name: "prisma_analyze"}] = Prisma.language_tools(:erlang)
    end

    test "language_tools/1 contributes nothing for an unserved language" do
      assert Prisma.language_tools(:python) == []
      assert Prisma.language_tools(:ruby) == []
    end

    test "every declared language is known to Ragex.Languages" do
      # The registry refuses to register a plugin declaring an unknown
      # language, so this guards against a silent registration failure.
      for language <- Prisma.languages() do
        assert Ragex.Languages.supported?(language)
      end
    end
  end

  describe "available?/1" do
    test "is false for a project without a prisma dependency" do
      refute Prisma.available?(tmp_project())
    end

    test "is true when mix.lock lists prisma" do
      dir = tmp_project()

      File.write!(
        Path.join(dir, "mix.lock"),
        ~s(%{"prisma": {:hex, :prisma, "0.2.0", "x", [:rebar3], [], "hexpm", "y"}})
      )

      assert Prisma.available?(dir)
    end
  end

  describe "execute/2" do
    test "rejects unknown tools" do
      assert {:error, msg} = Prisma.execute("nope", %{})
      assert msg =~ "Unknown tool 'nope'"
    end

    test "reports an actionable error when Prisma is unavailable" do
      assert {:error, message} = Prisma.execute("prisma_analyze", %{"path" => tmp_project()})
      assert message =~ "Prisma is not available"
      assert message =~ "mix prisma.build"
    end
  end

  # Creates a throwaway project directory, removed when the test ends.
  #
  # The name is unique across runs -- `System.unique_integer([:positive])`
  # restarts at each BEAM start, so it would let a later run inherit a
  # directory (and a `mix.lock`) a previous run left behind.
  defp tmp_project do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ragex_prisma_plugin_#{System.system_time(:nanosecond)}_#{:rand.uniform(1_000_000)}"
      )

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
