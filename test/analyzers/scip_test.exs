defmodule Ragex.Analyzers.SCIPTest do
  use ExUnit.Case, async: true

  alias Ragex.Analyzers.Directory
  alias Ragex.Analyzers.SCIP.{Adapter, Parser, Registry}
  alias Ragex.MCP.Handlers.SCIPTools

  # ── Registry ─────────────────────────────────────────────────────────

  describe "Registry" do
    test "all_languages/0 returns 10 language definitions" do
      langs = Registry.all_languages()
      assert length(langs) == 10
      names = Enum.map(langs, & &1.language)
      assert "go" in names
      assert "rust" in names
      assert "java" in names
      assert "ruby" in names
    end

    test "detect_languages/1 finds Go project" do
      dir = Path.join(System.tmp_dir!(), "scip_test_go_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "go.mod"), "module example.com/test")

      detected = Registry.detect_languages(dir)
      assert [%{language: "go"}] = detected

      File.rm_rf!(dir)
    end

    test "detect_languages/1 returns empty for non-SCIP project" do
      dir = Path.join(System.tmp_dir!(), "scip_test_elixir_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "")

      assert Registry.detect_languages(dir) == []

      File.rm_rf!(dir)
    end

    test "scip_extensions/0 returns file extensions" do
      exts = Registry.scip_extensions()
      assert ".go" in exts
      assert ".rs" in exts
      assert ".java" in exts
    end

    test "get_language/1 returns info for known language" do
      assert %{language: "go", indexer: "scip-go"} = Registry.get_language("go")
    end

    test "get_language/1 returns nil for unknown language" do
      assert Registry.get_language("brainfuck") == nil
    end

    test "scip_cli_available?/0 returns a boolean" do
      assert is_boolean(Registry.scip_cli_available?())
    end
  end

  # ── Parser ───────────────────────────────────────────────────────────

  describe "Parser" do
    @fixture_json :json.encode(%{
                    "metadata" => %{
                      "version" => 0,
                      "toolInfo" => %{"name" => "scip-go", "version" => "0.3.0"},
                      "projectRoot" => "file:///opt/project"
                    },
                    "documents" => [
                      %{
                        "relativePath" => "main.go",
                        "language" => "go",
                        "symbols" => [
                          %{
                            "symbol" => "scip-go go example.com/test 0.1.0 main/",
                            "documentation" => ["Package main"]
                          },
                          %{
                            "symbol" => "scip-go go example.com/test 0.1.0 main/Handler#",
                            "documentation" => ["Handler struct"]
                          },
                          %{
                            "symbol" =>
                              "scip-go go example.com/test 0.1.0 main/Handler#ServeHTTP().",
                            "documentation" => ["ServeHTTP handles requests"]
                          }
                        ],
                        "occurrences" => [
                          %{
                            "symbol" =>
                              "scip-go go example.com/test 0.1.0 main/Handler#ServeHTTP().",
                            "symbolRoles" => 1,
                            "range" => [10, 5, 10, 14]
                          },
                          %{
                            "symbol" => "scip-go go net/http 0.0.0 ResponseWriter#",
                            "symbolRoles" => 0,
                            "range" => [11, 2, 11, 16]
                          }
                        ]
                      }
                    ]
                  })
                  |> IO.iodata_to_binary()

    test "parse/2 extracts modules from SCIP JSON" do
      {:ok, result} = Parser.parse(@fixture_json, "/opt/project")

      assert match?([_ | _], result.modules)
      assert result.metadata.tool == "scip-go"
    end

    test "parse/2 extracts functions from SCIP JSON" do
      {:ok, result} = Parser.parse(@fixture_json, "/opt/project")

      func_names = Enum.map(result.functions, & &1.name)
      assert :ServeHTTP in func_names
    end

    test "parse/2 returns error for invalid JSON" do
      assert {:error, _} = Parser.parse("not json", "/opt/project")
    end

    test "parse_symbols/1 returns flat symbol list" do
      {:ok, symbols} = Parser.parse_symbols(@fixture_json)
      assert length(symbols) >= 2
      assert Enum.all?(symbols, &Map.has_key?(&1, :kind))
    end
  end

  # ── Adapter ──────────────────────────────────────────────────────────

  describe "Adapter" do
    test "ingest/2 stores analysis into knowledge graph" do
      analysis = %{
        modules: [%{name: :TestSCIPModule, file: "/tmp/test.go", line: 1}],
        functions: [
          %{name: :serve, arity: 0, module: :TestSCIPModule, file: "/tmp/test.go", line: 5}
        ],
        calls: [],
        imports: []
      }

      assert {:ok, stats} = Adapter.ingest(analysis)
      assert stats.modules == 1
      assert stats.functions == 1
      assert stats.source == :scip
    end
  end

  # ── MCP Tools ────────────────────────────────────────────────────────

  describe "SCIPTools" do
    test "tool_definitions/0 returns 2 tools" do
      defs = SCIPTools.tool_definitions()
      assert [_, _] = defs
      names = Enum.map(defs, & &1.name)
      assert "scip_status" in names
      assert "scip_index" in names
    end

    test "call_tool/2 handles scip_status" do
      {:ok, result} = SCIPTools.call_tool("scip_status", %{"path" => File.cwd!()})
      assert is_boolean(result.scip_cli_available)
      assert is_list(result.all_supported_languages)
      assert length(result.all_supported_languages) == 10
    end

    test "call_tool/2 returns error for unknown tool" do
      assert {:error, _} = SCIPTools.call_tool("nonexistent", %{})
    end
  end

  # ── Auto-SCIP Indexing Integration ───────────────────────────────────

  describe "directory auto-SCIP indexing" do
    test "analyze_directory/2 triggers auto_index_scip and handles missing binary gracefully" do
      # Create a temp directory with a go.mod file (SCIP marker)
      dir = Path.join(System.tmp_dir!(), "scip_auto_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "go.mod"), "module example.com/test")

      # Also add one elixir file so directory analysis completes normally
      File.write!(Path.join(dir, "lib.ex"), "defmodule Lib do; end")

      # Enable auto SCIP in config
      Application.put_env(:ragex, :enable_auto_scip, true)

      # Directory analysis should complete without crashing even if scip-go is missing
      assert {:ok, result} = Directory.analyze_directory(dir, notify: false)
      assert result.success >= 1

      File.rm_rf!(dir)
    end
  end
end
