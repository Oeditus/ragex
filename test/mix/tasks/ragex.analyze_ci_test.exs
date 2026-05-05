defmodule Mix.Tasks.Ragex.AnalyzeCITest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ragex.Analyze

  describe "build_config/1 - new flags" do
    test "defaults: all analyses enabled including new ones" do
      config = Analyze.build_config([])

      assert config.analyses.circulars == true
      assert config.analyses.god_modules == true
      assert config.analyses.unstable_modules == true
      assert config.analyses.unused_modules == true
      assert config.analyses.coupling == true
      assert config.ci == false
      assert config.strict == false
    end

    test "selecting --circulars disables other analyses" do
      config = Analyze.build_config(circulars: true)

      assert config.analyses.circulars == true
      assert config.analyses.security == false
      assert config.analyses.quality == false
      assert config.analyses.god_modules == false
    end

    test "selecting multiple new flags enables only those" do
      config = Analyze.build_config(circulars: true, god_modules: true, unused_modules: true)

      assert config.analyses.circulars == true
      assert config.analyses.god_modules == true
      assert config.analyses.unused_modules == true
      assert config.analyses.unstable_modules == false
      assert config.analyses.coupling == false
      assert config.analyses.security == false
    end

    test "--all re-enables everything" do
      config = Analyze.build_config(circulars: true, all: true)

      assert config.analyses.circulars == true
      assert config.analyses.security == true
      assert config.analyses.god_modules == true
    end

    test "--ci flag sets ci mode" do
      config = Analyze.build_config(ci: true, circulars: true)

      assert config.ci == true
      assert config.strict == false
    end

    test "--strict flag sets strict mode" do
      config = Analyze.build_config(strict: true)

      assert config.strict == true
      assert config.ci == false
    end

    test "--god-threshold overrides default" do
      config = Analyze.build_config(god_threshold: 25)
      assert config.god_threshold == 25
    end

    test "--instability-threshold overrides default" do
      config = Analyze.build_config(instability_threshold: 0.95)
      assert config.instability_threshold == 0.95
    end

    test "default thresholds" do
      config = Analyze.build_config([])
      assert config.god_threshold == 15
      assert config.instability_threshold == 0.8
    end
  end

  describe "count_ci_issues/1" do
    test "counts circulars" do
      results = %{circulars: %{cycles: [[:A, :B], [:C, :D, :E]]}}
      assert Analyze.count_ci_issues(results) == 2
    end

    test "counts god modules" do
      results = %{
        god_modules: %{
          modules: [
            %{module: :A, afferent: 10, efferent: 8, total: 18, instability: 0.44}
          ]
        }
      }

      assert Analyze.count_ci_issues(results) == 1
    end

    test "counts unstable modules" do
      results = %{
        unstable_modules: %{
          modules: [
            %{module: :A, instability: 0.95, afferent: 1, efferent: 10},
            %{module: :B, instability: 0.85, afferent: 2, efferent: 8}
          ]
        }
      }

      assert Analyze.count_ci_issues(results) == 2
    end

    test "counts unused modules" do
      results = %{unused_modules: %{modules: [:X, :Y, :Z]}}
      assert Analyze.count_ci_issues(results) == 3
    end

    test "coupling and quality are not counted as issues" do
      results = %{
        coupling: %{
          metrics: [
            %{module: :A, afferent: 1, efferent: 2, instability: 0.67}
          ]
        },
        quality: %{overall_score: 50}
      }

      assert Analyze.count_ci_issues(results) == 0
    end

    test "aggregates across multiple types" do
      results = %{
        circulars: %{cycles: [[:A, :B]]},
        god_modules: %{
          modules: [%{module: :C, afferent: 10, efferent: 10, total: 20, instability: 0.5}]
        },
        unused_modules: %{modules: [:X]},
        coupling: %{metrics: [%{module: :A, afferent: 1, efferent: 2, instability: 0.67}]}
      }

      assert Analyze.count_ci_issues(results) == 3
    end

    test "empty results count as zero" do
      results = %{
        circulars: %{cycles: []},
        god_modules: %{modules: []},
        unstable_modules: %{modules: []},
        unused_modules: %{modules: []}
      }

      assert Analyze.count_ci_issues(results) == 0
    end
  end
end
