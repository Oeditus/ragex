defmodule Mix.Tasks.Ragex.CiSwitchesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ragex.Analyze
  alias Ragex.Analysis.MetaCredoBridge
  alias Ragex.Analysis.Runner

  describe "MetaCredoBridge db_check? and user_check?" do
    test "db_check? detects DB checks" do
      assert MetaCredoBridge.db_check?(MetaCredo.Check.Warning.NPlusOneQuery)
      assert MetaCredoBridge.db_check?(MetaCredo.Check.Warning.MissingPreload)
      assert MetaCredoBridge.db_check?(MetaCredo.Check.Security.SQLInjection)
      assert MetaCredoBridge.db_check?(:n_plus_one_query)
      assert MetaCredoBridge.db_check?(:missing_preload)
      assert MetaCredoBridge.db_check?(:sql_injection)

      refute MetaCredoBridge.db_check?(MetaCredo.Check.Warning.CallbackHell)
      refute MetaCredoBridge.db_check?(:callback_hell)
    end

    test "user_check? detects user input checks" do
      assert MetaCredoBridge.user_check?(MetaCredo.Check.Security.XSSVulnerability)
      assert MetaCredoBridge.user_check?(MetaCredo.Check.Security.PathTraversal)
      assert MetaCredoBridge.user_check?(MetaCredo.Check.Security.SSRFVulnerability)
      assert MetaCredoBridge.user_check?(MetaCredo.Check.Security.ImproperInputValidation)
      assert MetaCredoBridge.user_check?(:xss_vulnerability)
      assert MetaCredoBridge.user_check?(:path_traversal)

      refute MetaCredoBridge.user_check?(MetaCredo.Check.Warning.CallbackHell)
      refute MetaCredoBridge.user_check?(:callback_hell)
    end

    test "filter_checks filters checks based on no_db and no_user" do
      checks = [
        {MetaCredo.Check.Warning.NPlusOneQuery, []},
        {MetaCredo.Check.Security.XSSVulnerability, []},
        {MetaCredo.Check.Warning.CallbackHell, []}
      ]

      no_db_filtered = MetaCredoBridge.filter_checks(checks, no_db: true)
      assert length(no_db_filtered) == 2

      refute Enum.any?(no_db_filtered, fn {mod, _} ->
               mod == MetaCredo.Check.Warning.NPlusOneQuery
             end)

      no_user_filtered = MetaCredoBridge.filter_checks(checks, no_user: true)
      assert length(no_user_filtered) == 2

      refute Enum.any?(no_user_filtered, fn {mod, _} ->
               mod == MetaCredo.Check.Security.XSSVulnerability
             end)

      both_filtered = MetaCredoBridge.filter_checks(checks, no_db: true, no_user: true)
      assert length(both_filtered) == 1
      assert Enum.at(both_filtered, 0) == {MetaCredo.Check.Warning.CallbackHell, []}
    end

    test "filter_checks works with atom list" do
      analyzers = [:n_plus_one_query, :xss_vulnerability, :callback_hell]

      no_db_filtered = MetaCredoBridge.filter_checks(analyzers, no_db: true)
      assert no_db_filtered == [:xss_vulnerability, :callback_hell]

      no_user_filtered = MetaCredoBridge.filter_checks(analyzers, no_user: true)
      assert no_user_filtered == [:n_plus_one_query, :callback_hell]

      both_filtered = MetaCredoBridge.filter_checks(analyzers, no_db: true, no_user: true)
      assert both_filtered == [:callback_hell]
    end
  end

  describe "Analyze.build_config/1 --no-db and --no-user" do
    test "parses no_db and no_user options" do
      config = Analyze.build_config(no_db: true, no_user: true)
      assert config.no_db == true
      assert config.no_user == true

      config_default = Analyze.build_config([])
      assert config_default.no_db == false
      assert config_default.no_user == false
    end
  end

  describe "Runner.filter_results_by_switches/2" do
    test "suppresses db and user input issues from analysis results" do
      results = %{
        business_logic: %{
          total_issues: 3,
          files_with_issues: 1,
          results: [
            %{
              file: "lib/test.ex",
              has_issues?: true,
              issues: [
                %{analyzer: :n_plus_one_query, description: "N+1 query"},
                %{analyzer: :xss_vulnerability, description: "XSS vuln"},
                %{analyzer: :callback_hell, description: "Callback hell"}
              ]
            }
          ]
        },
        security: %{
          issues: [
            %{category: :sql_injection, description: "SQL Injection"},
            %{category: :path_traversal, description: "Path Traversal"},
            %{category: :hardcoded_value, description: "Hardcoded key"}
          ]
        }
      }

      no_db_results =
        Runner.filter_results_by_switches(results, %{no_db: true, no_user: false})

      bl_issues = get_in(no_db_results, [:business_logic, :results, Access.at(0), :issues])
      assert length(bl_issues) == 2
      refute Enum.any?(bl_issues, &(&1.analyzer == :n_plus_one_query))

      sec_issues = get_in(no_db_results, [:security, :issues])
      refute Enum.any?(sec_issues, &(&1.category == :sql_injection))

      no_user_results =
        Runner.filter_results_by_switches(results, %{no_db: false, no_user: true})

      bl_issues_user = get_in(no_user_results, [:business_logic, :results, Access.at(0), :issues])
      assert length(bl_issues_user) == 2
      refute Enum.any?(bl_issues_user, &(&1.analyzer == :xss_vulnerability))

      sec_issues_user = get_in(no_user_results, [:security, :issues])
      refute Enum.any?(sec_issues_user, &(&1.category == :path_traversal))

      both_results =
        Runner.filter_results_by_switches(results, %{no_db: true, no_user: true})

      bl_issues_both = get_in(both_results, [:business_logic, :results, Access.at(0), :issues])
      assert length(bl_issues_both) == 1
      assert Enum.at(bl_issues_both, 0).analyzer == :callback_hell
    end
  end
end
