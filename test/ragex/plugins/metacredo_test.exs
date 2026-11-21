defmodule Ragex.Plugins.MetaCredoTest do
  use ExUnit.Case, async: true

  alias Ragex.Plugins.MetaCredo

  describe "plugin contract" do
    test "info/0 metadata is complete" do
      info = MetaCredo.info()

      assert info.id == :metacredo
      assert info.category == :analyzer
      assert info.dependencies == []
      assert is_binary(info.version)
      assert is_binary(info.description)
    end

    test "tools/0 advertises metacredo_analyze with path required" do
      assert [schema] = MetaCredo.tools()

      assert schema.name == "metacredo_analyze"
      assert schema.destruction_level == :none
      assert schema.inputSchema.required == ["path"]
      assert schema.inputSchema.properties.path.default == "."
    end

    test "the schema documents the diff-review switches" do
      properties = MetaCredo.tools() |> hd() |> get_in([:inputSchema, :properties])

      for key <- [:diff, :base, :head, :diff_lines, :files, :min_confidence, :config] do
        assert Map.has_key?(properties, key), "expected #{key} to be documented"
      end
    end

    test "the description warns that an empty diff is not a clean result" do
      assert MetaCredo.tool_schema().description =~ "partial"
    end

    test "every advertised tool has a dispatch clause" do
      # A tool advertised without a clause is a trap: the registry would offer
      # it and every call would fail with "Unknown tool". A non-string `path`
      # is rejected before any analysis runs, so this stays cheap -- calling
      # with `%{}` would default `path` to "." and analyse the whole project.
      for %{name: name} <- MetaCredo.tools() do
        case MetaCredo.execute(name, %{"path" => 123}) do
          {:error, msg} -> refute msg =~ "Unknown tool", "#{name} has no dispatch clause"
          _ -> :ok
        end
      end
    end
  end

  describe "language scoping" do
    test "serves every language Metastatic can parse" do
      # MetaCredo checks operate on MetaAST, so they are not Elixir-specific.
      assert :elixir in MetaCredo.languages()
      assert :python in MetaCredo.languages()
      assert :ruby in MetaCredo.languages()
    end

    test "language_tools/1 returns the tool for a supported language" do
      assert [%{name: "metacredo_analyze"}] = MetaCredo.language_tools(:elixir)
      assert MetaCredo.language_tools(:cobol) == []
    end

    test "available?/1 is always true" do
      assert MetaCredo.available?()
      assert MetaCredo.available?(".")
    end
  end

  describe "execute/2" do
    test "rejects unknown tools" do
      assert {:error, msg} = MetaCredo.execute("nope", %{})
      assert msg =~ "Unknown tool 'nope'"
    end

    test "validates its arguments" do
      assert {:error, msg} = MetaCredo.execute("metacredo_analyze", %{"path" => 123})
      assert msg =~ "must be a string"
    end

    test "runs a real analysis" do
      assert {:ok, report} =
               MetaCredo.execute("metacredo_analyze", %{
                 "path" => "lib/ragex/plugin/registry.ex"
               })

      assert report.status == "success"
      assert report.source == "metacredo"
      assert report.files_analyzed == 1
    end
  end
end
