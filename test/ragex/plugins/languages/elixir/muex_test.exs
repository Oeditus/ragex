defmodule Ragex.Plugins.Languages.Elixir.MuexTest do
  use ExUnit.Case, async: true

  alias Ragex.Plugins.Languages.Elixir.Muex

  describe "tool_schema/0" do
    test "advertises muex_analyze with path required" do
      schema = Muex.tool_schema()

      assert schema.name == "muex_analyze"
      assert schema.destruction_level == :none
      assert schema.inputSchema.required == ["path"]
      assert schema.inputSchema.properties.path.default == "."
    end

    test "documents that the score is a range, not a single number" do
      description = Muex.tool_schema().description

      assert description =~ "score_low"
      assert description =~ "score_high"
    end

    test "warns that a run executes the test suite once per mutant" do
      assert Muex.tool_schema().description =~ "once per mutant"
    end

    test "exposes the bounding options that keep a run affordable" do
      properties = Muex.tool_schema().inputSchema.properties

      # Schema property keys are atoms, matching the rest of the plugin tools.
      for key <- [:max_mutations, :since, :optimize_level, :coverage_guided, :deadline_minutes] do
        assert Map.has_key?(properties, key), "expected #{key} to be documented"
      end
    end

    test "only offers the optimize levels Muex actually accepts" do
      assert Muex.tool_schema().inputSchema.properties.optimize_level.enum ==
               ~w(conservative balanced aggressive)
    end
  end

  describe "run/1 argument validation" do
    test "rejects a call with no path" do
      assert {:error, msg} = Muex.run(%{})
      assert msg =~ "requires a \"path\" argument"
    end

    test "rejects a non-binary path" do
      assert {:error, msg} = Muex.run(%{"path" => 123})
      assert msg =~ "requires a \"path\" argument"
    end

    test "reports a missing mix.exs instead of shelling out" do
      dir = tmp_dir!("not_a_mix_project")

      assert {:error, msg} = Muex.run(%{"path" => dir})
      assert msg =~ "no mix.exs"
      assert msg =~ dir
    end
  end

  describe "run/1 against a project without Muex" do
    # The realistic failure: a Mix project that does not depend on Muex. `mix
    # muex` exits 1 with "The task \"muex\" could not be found". The bridge
    # must surface that as an error rather than reporting a clean run.
    @tag :external
    @tag timeout: 120_000
    test "surfaces mix's error rather than reporting a score" do
      dir = tmp_dir!("mix_project_without_muex")

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule NoMuex.MixProject do
        use Mix.Project

        def project, do: [app: :no_muex, version: "0.1.0", elixir: "~> 1.15"]
      end
      """)

      case Muex.run(%{"path" => dir}) do
        {:error, {:exit, code, output}} ->
          assert code == 1
          assert output =~ "muex"

        # A machine with muex installed as a global archive would actually run
        # it and find no lib/ to mutate; either way it must not claim a score.
        {:ok, report} ->
          assert report.total_mutants == 0

        # `mix` can report the missing task without a usable JSON payload, in
        # which case the bridge refuses to invent a score and says so. Both
        # shapes are acceptable; reporting a clean run is not.
        {:error, {:no_report, output}} ->
          assert output =~ "muex"

        {:error, other} ->
          flunk("unexpected error shape: #{inspect(other)}")
      end
    end
  end

  describe "available?/1" do
    test "returns a boolean" do
      assert is_boolean(Muex.available?())
      assert is_boolean(Muex.available?("."))
    end
  end

  describe "CLI argument mapping" do
    # The flags are forwarded by name to `mix muex`, which parses them with a
    # strict OptionParser spec. These assertions pin the contract against
    # Muex's `@option_spec`, so a rename is caught here rather than producing a
    # run that quietly ignores the caller's bounds. `cli_args/1` is exercised
    # as a `@doc false` seam specifically for this.
    test "forwards only the options the caller actually set" do
      assert Muex.cli_args(%{}) == []

      args = Muex.cli_args(%{"since" => "main", "max_mutations" => 50})

      assert args == ["--since", "main", "--max-mutations", "50"]
    end

    test "omits options left at nil rather than passing an empty value" do
      refute "--since" in Muex.cli_args(%{"since" => nil})
    end

    test "--coverage-guided is a bare flag, present only when true" do
      assert "--coverage-guided" in Muex.cli_args(%{"coverage_guided" => true})
      refute "--coverage-guided" in Muex.cli_args(%{"coverage_guided" => false})
      refute "--coverage-guided" in Muex.cli_args(%{})
    end

    test "every forwarded flag is one Muex's OptionParser spec accepts" do
      # Muex's strict spec rejects unknown flags outright, so a typo here would
      # turn the whole run into an error rather than a silently ignored bound.
      accepted = ~w(
        --files --test-paths --language --mutators --optimize-level --since
        --max-mutations --fail-at --concurrency --timeout --deadline-minutes
        --coverage-guided --format
      )

      params = %{
        "files" => "lib",
        "test_paths" => "test",
        "language" => "elixir",
        "mutators" => "arithmetic",
        "optimize_level" => "conservative",
        "since" => "main",
        "max_mutations" => 10,
        "fail_at" => 80,
        "concurrency" => 2,
        "timeout" => 5_000,
        "deadline_minutes" => 2.5,
        "coverage_guided" => true
      }

      flags = params |> Muex.cli_args() |> Enum.filter(&String.starts_with?(&1, "--"))

      for flag <- flags do
        assert flag in accepted, "#{flag} is not in Muex's option spec"
      end

      assert length(flags) == map_size(params)
    end
  end

  # The parsing and formatting stages are pure, so they are exercised through
  # the module's public surface only where possible. These fixtures mirror the
  # exact shape `Muex.Reporter.Json` emits.
  describe "report shape (via a real Muex report fixture)" do
    setup do
      report = %{
        "results" => [
          %{
            "result" => "killed",
            "mutation" => %{
              "file" => "lib/cart.ex",
              "line" => 12,
              "mutator" => "Muex.Mutator.Arithmetic",
              "description" => "arithmetic + -> -",
              "original" => "+",
              "mutated" => "-"
            }
          },
          %{
            "result" => "survived",
            "mutation" => %{
              "file" => "lib/cart.ex",
              "line" => 30,
              "mutator" => "Muex.Mutator.Comparison",
              "description" => "comparison > -> >=",
              "original" => ">",
              "mutated" => ">="
            }
          },
          %{
            "result" => "equivalent",
            "mutation" => %{"file" => "lib/cart.ex", "line" => 44}
          }
        ],
        "score_low" => 50.0,
        "score_high" => 50.0,
        "partial" => nil
      }

      {:ok, report: report}
    end

    test "the fixture is valid JSON round-trippable", %{report: report} do
      assert {:ok, decoded} = report |> Jason.encode!() |> Jason.decode()
      assert length(decoded["results"]) == 3
    end
  end

  defp tmp_dir!(name) do
    dir = Path.join(System.tmp_dir!(), "ragex_muex_#{name}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
