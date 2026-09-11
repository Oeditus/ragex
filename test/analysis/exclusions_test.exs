defmodule Ragex.Analysis.ExclusionsTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.Exclusion
  alias Ragex.Analysis.Exclusions

  describe "parse_location_string/1" do
    test "parses path with line number" do
      assert {"lib/ragex/analyzers/directory.ex", 248} ==
               Exclusions.parse_location_string("lib/ragex/analyzers/directory.ex:248")
    end

    test "parses path without line number" do
      assert {"lib/ragex/analyzers/directory.ex", nil} ==
               Exclusions.parse_location_string("lib/ragex/analyzers/directory.ex")
    end
  end

  describe "parse_exclusion_item/1" do
    test ~s(parses user format tuple {"file:line", "rule"}) do
      assert [
               %Exclusion{
                 file: "lib/ragex/analyzers/directory.ex",
                 line: 248,
                 rule: "long_parameter_list"
               }
             ] =
               Exclusions.parse_exclusion_item(
                 {"lib/ragex/analyzers/directory.ex:248", "long_parameter_list"}
               )
    end

    test "parses atom rule format {\"file:line\", :rule}" do
      assert [
               %Exclusion{
                 file: "lib/ragex/analyzers/directory.ex",
                 line: 248,
                 rule: "long_parameter_list"
               }
             ] =
               Exclusions.parse_exclusion_item(
                 {"lib/ragex/analyzers/directory.ex:248", :long_parameter_list}
               )
    end

    test ~s(parses 3-tuple format {"file", line, "rule"}) do
      assert [
               %Exclusion{
                 file: "lib/ragex/analyzers/directory.ex",
                 line: 248,
                 rule: "long_parameter_list"
               }
             ] =
               Exclusions.parse_exclusion_item(
                 {"lib/ragex/analyzers/directory.ex", 248, "long_parameter_list"}
               )
    end

    test ~s(parses line-agnostic tuple {"file", "rule"}) do
      assert [
               %Exclusion{
                 file: "lib/ragex/analyzers/directory.ex",
                 line: nil,
                 rule: "long_parameter_list"
               }
             ] =
               Exclusions.parse_exclusion_item(
                 {"lib/ragex/analyzers/directory.ex", "long_parameter_list"}
               )
    end
  end

  describe "parse_config_result/1" do
    test "parses top-level list of exclusion tuples" do
      config = [
        {"lib/ragex/analyzers/directory.ex:248", "long_parameter_list"},
        {"lib/my_app/user.ex:50", :magic_number}
      ]

      exclusions = Exclusions.parse_config_result(config)
      assert length(exclusions) == 2
      assert Enum.at(exclusions, 0).file == "lib/ragex/analyzers/directory.ex"
      assert Enum.at(exclusions, 0).line == 248
      assert Enum.at(exclusions, 0).rule == "long_parameter_list"
    end

    test "parses map with exclusions key" do
      config = %{
        exclusions: [
          {"lib/ragex/analyzers/directory.ex:248", "long_parameter_list"}
        ]
      }

      exclusions = Exclusions.parse_config_result(config)
      assert length(exclusions) == 1
      assert Enum.at(exclusions, 0).rule == "long_parameter_list"
    end
  end

  describe "excluded?/4" do
    setup do
      exclusions =
        Exclusions.parse_config_result([
          {"lib/ragex/analyzers/directory.ex:248", "long_parameter_list"},
          {"lib/ragex/analyzers/other.ex", "magic_number"}
        ])

      {:ok, exclusions: exclusions}
    end

    test "matches exact file, line, and rule", %{exclusions: exclusions} do
      assert Exclusions.excluded?(
               "lib/ragex/analyzers/directory.ex",
               248,
               :long_parameter_list,
               exclusions
             )

      assert Exclusions.excluded?(
               "lib/ragex/analyzers/directory.ex",
               248,
               "long_parameter_list",
               exclusions
             )

      assert Exclusions.excluded?(
               "lib/ragex/analyzers/directory.ex",
               248,
               "LongParameterList",
               exclusions
             )
    end

    test "does not match different line number", %{exclusions: exclusions} do
      refute Exclusions.excluded?(
               "lib/ragex/analyzers/directory.ex",
               249,
               :long_parameter_list,
               exclusions
             )
    end

    test "does not match different rule on same line", %{exclusions: exclusions} do
      refute Exclusions.excluded?(
               "lib/ragex/analyzers/directory.ex",
               248,
               :cyclomatic_complexity,
               exclusions
             )
    end

    test "matches line-agnostic exclusion on any line", %{exclusions: exclusions} do
      assert Exclusions.excluded?("lib/ragex/analyzers/other.ex", 10, :magic_number, exclusions)
      assert Exclusions.excluded?("lib/ragex/analyzers/other.ex", 999, :magic_number, exclusions)
    end
  end

  describe "filter_results/2" do
    setup do
      exclusions =
        Exclusions.parse_config_result([
          {"lib/ragex/analyzers/directory.ex:248", "long_parameter_list"}
        ])

      {:ok, exclusions: exclusions}
    end

    test "filters out business_logic issue on matching line and rule", %{exclusions: exclusions} do
      results = %{
        business_logic: %{
          total_issues: 2,
          files_with_issues: 1,
          results: [
            %{
              file: "lib/ragex/analyzers/directory.ex",
              has_issues?: true,
              issues: [
                %{
                  analyzer: :long_parameter_list,
                  line: 248,
                  file: "lib/ragex/analyzers/directory.ex",
                  description: "Too many params"
                },
                %{
                  analyzer: :silent_error_case,
                  line: 300,
                  file: "lib/ragex/analyzers/directory.ex",
                  description: "Silent error"
                }
              ]
            }
          ]
        }
      }

      filtered = Exclusions.filter_results(results, exclusions)
      bl_results = filtered.business_logic.results |> List.first()

      assert length(bl_results.issues) == 1
      assert List.first(bl_results.issues).analyzer == :silent_error_case
      assert filtered.business_logic.total_issues == 1
    end
  end

  describe "load/1" do
    test "loads exclusions from a config file on disk" do
      tmp_path = Path.join(System.tmp_dir!(), "test_ragex_config_#{System.unique_integer()}.exs")

      file_content = """
      [
        {"lib/ragex/analyzers/directory.ex:248", "long_parameter_list"},
        {"lib/my_app/user.ex:50", "magic_number"}
      ]
      """

      File.write!(tmp_path, file_content)

      try do
        exclusions = Exclusions.load(tmp_path)
        assert length(exclusions) == 2
        assert Enum.at(exclusions, 0).file == "lib/ragex/analyzers/directory.ex"
        assert Enum.at(exclusions, 0).line == 248
        assert Enum.at(exclusions, 0).rule == "long_parameter_list"
      after
        File.rm(tmp_path)
      end
    end
  end
end
