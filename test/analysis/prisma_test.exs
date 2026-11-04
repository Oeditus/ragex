defmodule Ragex.Analysis.PrismaTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.Prisma
  alias Ragex.MCP.Handlers.Tools
  alias Ragex.Plugins.CodeQuality

  @prisma_json """
  Compiling 3 files (.ex)
  [
    {
      "kind": "gradual_mismatch",
      "severity": "error",
      "module": "MyApp.User",
      "function": "age",
      "arity": 1,
      "line": 12,
      "message": "declared non_neg_integer() but body returns integer()",
      "file": "lib/my_app/user.ex",
      "declared": "non_neg_integer()",
      "actual": "integer()"
    },
    {
      "kind": "oxbow_code",
      "severity": "warning",
      "module": "MyApp.Helper",
      "function": "unused",
      "arity": 0,
      "line": 30,
      "message": "function is never called"
    }
  ]
  """

  @empty_json """
  [
  ]
  """

  describe "available?/1" do
    test "is false for a project without a prisma dependency" do
      refute Prisma.available?(tmp_project(%{}))
    end

    test "is true when mix.lock lists prisma" do
      root =
        tmp_project(%{
          "mix.lock" =>
            ~s(%{"prisma": {:hex, :prisma, "0.1.0", "x", [:rebar3], [], "hexpm", "y"}})
        })

      assert Prisma.available?(root)
    end

    test "is false for a non-existent project root" do
      refute Prisma.available?("/definitely/not/a/real/path")
    end
  end

  describe "analyze/2 when Prisma is unavailable" do
    test "returns {:error, :unavailable} instead of raising" do
      assert {:error, :unavailable} = Prisma.analyze(tmp_project(%{}))
    end
  end

  describe "MCP tool integration" do
    test "is advertised by the CodeQuality plugin" do
      names = CodeQuality.tools() |> Enum.map(& &1.name)
      assert "prisma_analyze" in names
    end

    test "returns an actionable error when Prisma is unavailable" do
      assert {:error, message} =
               Tools.prisma_analyze_tool(%{"path" => tmp_project(%{})})

      assert message =~ "Prisma is not available"
      assert message =~ "mix prisma.build"
    end
  end

  describe "to_dead_code_suggestions/1" do
    test "converts oxbow findings into review suggestions" do
      findings = [
        finding("oxbow_code", "MyApp.Helper", "unused", 0),
        finding("dead_code", "MyApp.Other", "stale", 2)
      ]

      assert [first, second] = Prisma.to_dead_code_suggestions(findings)

      assert first.type == :review_function
      assert first.target.module == "MyApp.Helper"
      assert first.target.name == "unused"
      assert first.target.arity == 0
      assert first.metadata.source == :prisma
      assert first.metadata.kind == "oxbow_code"

      assert second.target.name == "stale"
    end

    test "ignores type findings, which have no dead-code counterpart" do
      findings = [
        finding("gradual_mismatch", "MyApp.User", "age", 1),
        finding("unknown_function", "MyApp.User", "nope", 2)
      ]

      assert Prisma.to_dead_code_suggestions(findings) == []
    end

    test "returns an empty list for no findings" do
      assert Prisma.to_dead_code_suggestions([]) == []
    end
  end

  describe "JSON parsing (via the public analyze path)" do
    # These exercise the parser by driving `analyze/2` against a fake project
    # whose `mix prisma` is stubbed by a shell script placed first on PATH.
    @describetag :tmp_dir

    test "parses a Prisma JSON array and normalizes keys", %{tmp_dir: tmp_dir} do
      root = stub_project(tmp_dir, @prisma_json)

      assert {:ok, [first, second]} = with_stub_on_path(root, fn -> Prisma.analyze(root) end)

      assert first.kind == "gradual_mismatch"
      assert first.severity == :error
      assert first.module == "MyApp.User"
      assert first.function == "age"
      assert first.arity == 1
      assert first.line == 12
      assert first.declared == "non_neg_integer()"
      assert first.actual == "integer()"
      assert first.source == :prisma

      assert second.kind == "oxbow_code"
      assert second.severity == :warning
      # Absent optional keys normalize to nil rather than being missing
      assert second.declared == nil
    end

    test "treats an empty JSON array as a clean result", %{tmp_dir: tmp_dir} do
      root = stub_project(tmp_dir, @empty_json)

      assert {:ok, []} = with_stub_on_path(root, fn -> Prisma.analyze(root) end)
    end

    test "treats exit status 1 as a successful analysis with findings", %{tmp_dir: tmp_dir} do
      # Prisma exits 1 whenever it reports errors; that is not a failure.
      root = stub_project(tmp_dir, @prisma_json, exit_status: 1)

      assert {:ok, [_ | _]} = with_stub_on_path(root, fn -> Prisma.analyze(root) end)
    end

    test "reports a crash (exit status 2) as an error", %{tmp_dir: tmp_dir} do
      root = stub_project(tmp_dir, "boom", exit_status: 2)

      assert {:error, {:exit, 2, _output}} =
               with_stub_on_path(root, fn -> Prisma.analyze(root) end)
    end

    test "reports unparseable output as an error", %{tmp_dir: tmp_dir} do
      root = stub_project(tmp_dir, "not json at all", exit_status: 0)

      assert {:error, {:invalid_json, _}} =
               with_stub_on_path(root, fn -> Prisma.analyze(root) end)
    end
  end

  # --- helpers ---

  defp finding(kind, module, function, arity) do
    %{
      kind: kind,
      severity: :warning,
      module: module,
      function: function,
      arity: arity,
      line: 1,
      file: "lib/x.ex",
      message: "msg",
      declared: nil,
      actual: nil,
      expected: nil,
      source: :prisma
    }
  end

  defp tmp_project(files) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ragex_prisma_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    Enum.each(files, fn {name, content} ->
      File.write!(Path.join(dir, name), content)
    end)

    dir
  end

  # Builds a throwaway project whose `mix prisma` is a shell script that prints
  # the given output and exits with the given status. This lets the real
  # `System.cmd` path be exercised without Prisma installed.
  defp stub_project(dir, output, opts \\ []) do
    exit_status = Keyword.get(opts, :exit_status, 0)
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    script = Path.join(bin, "mix")

    File.write!(
      script,
      "#!/bin/sh\ncat <<'PRISMA_EOF'\n#{output}\nPRISMA_EOF\nexit #{exit_status}\n"
    )

    File.chmod!(script, 0o755)

    File.write!(Path.join(dir, "mix.lock"), ~s(%{"prisma": {:hex, :prisma, "0.1.0"}}))

    dir
  end

  # Runs `fun` with the stub project's bin directory prepended to PATH, so the
  # `System.cmd("mix", ...)` inside `Prisma.analyze/2` resolves to the stub.
  defp with_stub_on_path(dir, fun) do
    bin = Path.join(dir, "bin")
    original = System.get_env("PATH")
    System.put_env("PATH", "#{bin}:#{original}")

    try do
      fun.()
    after
      System.put_env("PATH", original)
    end
  end
end
