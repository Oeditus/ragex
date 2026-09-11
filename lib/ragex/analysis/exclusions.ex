defmodule Ragex.Analysis.Exclusion do
  @moduledoc """
  Represents a single issue exclusion rule loaded from `.ragex.exs`.
  """
  defstruct [:file, :line, :rule, :raw]

  @type t :: %__MODULE__{
          file: String.t(),
          line: integer() | nil,
          rule: String.t() | atom() | nil,
          raw: term()
        }
end

defmodule Ragex.Analysis.Exclusions do
  @moduledoc """
  Manages loading and filtering of analyze exclusions from `.ragex.exs`.

  Supports `.ragex.exs` config formats:

  ## Format 1: Top-level list of exclusion tuples
      [
        {"lib/ragex/analyzers/directory.ex:248", "long_parameter_list"},
        {"lib/ragex/analyzers/directory.ex", 150, "cyclomatic_complexity"},
        {"lib/my_app/user.ex:50", "magic_number"}
      ]

  ## Format 2: Map or Keyword list with an `:exclusions` key
      %{
        exclusions: [
          {"lib/ragex/analyzers/directory.ex:248", "long_parameter_list"}
        ]
      }
  """

  alias Ragex.Analysis.Exclusion
  require Logger

  @doc """
  Loads exclusion rules from `.ragex.exs` or custom config path.
  """
  @spec load(String.t() | map() | keyword() | nil) :: [Exclusion.t()]
  def load(opts_or_path \\ nil)

  def load(path) when is_binary(path) do
    do_load(path)
  end

  def load(opts) when is_map(opts) or is_list(opts) do
    path =
      opts[:ragex_config] ||
        opts[:config] ||
        System.get_env("RAGEX_CONFIG") ||
        ".ragex.exs"

    do_load(path)
  end

  def load(nil) do
    path = System.get_env("RAGEX_CONFIG") || ".ragex.exs"
    do_load(path)
  end

  defp do_load(path) do
    path = Path.expand(path)

    if File.exists?(path) do
      try do
        {eval_result, _} = Code.eval_file(path)
        parse_config_result(eval_result)
      rescue
        e ->
          Logger.warning("Failed to evaluate #{path}: #{inspect(e)}")
          []
      end
    else
      []
    end
  end

  @doc """
  Parses raw config evaluation result into a list of `%Exclusion{}` structs.
  """
  @spec parse_config_result(term()) :: [Exclusion.t()]
  def parse_config_result(list) when is_list(list) do
    if Keyword.keyword?(list) and Keyword.has_key?(list, :exclusions) do
      parse_config_result(Keyword.get(list, :exclusions, []))
    else
      Enum.flat_map(list, &parse_exclusion_item/1)
    end
  end

  def parse_config_result(%{exclusions: exclusions}) when is_list(exclusions) do
    Enum.flat_map(exclusions, &parse_exclusion_item/1)
  end

  def parse_config_result(%{"exclusions" => exclusions}) when is_list(exclusions) do
    Enum.flat_map(exclusions, &parse_exclusion_item/1)
  end

  def parse_config_result(_), do: []

  @doc """
  Parses an individual exclusion entry into an `%Exclusion{}` struct.
  """
  @spec parse_exclusion_item(term()) :: [Exclusion.t()]
  def parse_exclusion_item({location_str, rule}) when is_binary(location_str) do
    {file, line} = parse_location_string(location_str)
    [%Exclusion{file: file, line: line, rule: normalize_rule(rule), raw: {location_str, rule}}]
  end

  def parse_exclusion_item({location_str, line, rule})
      when is_binary(location_str) and is_integer(line) do
    {file, _} = parse_location_string(location_str)
    [%Exclusion{file: file, line: line, rule: normalize_rule(rule), raw: {location_str, line, rule}}]
  end

  def parse_exclusion_item({file, line, rule})
      when is_binary(file) and (is_integer(line) or is_nil(line)) do
    [%Exclusion{file: normalize_file_path(file), line: line, rule: normalize_rule(rule), raw: {file, line, rule}}]
  end

  def parse_exclusion_item(location_str) when is_binary(location_str) do
    {file, line} = parse_location_string(location_str)
    [%Exclusion{file: file, line: line, rule: nil, raw: location_str}]
  end

  def parse_exclusion_item(_), do: []

  @doc """
  Parses location strings like `"lib/ragex/analyzers/directory.ex:248"`.
  """
  @spec parse_location_string(String.t()) :: {String.t(), integer() | nil}
  def parse_location_string(str) when is_binary(str) do
    case Regex.run(~r/^(.*):(\d+)$/, str) do
      [_, file, line_str] ->
        {normalize_file_path(file), String.to_integer(line_str)}

      _ ->
        {normalize_file_path(str), nil}
    end
  end

  @doc """
  Normalizes file paths for consistent comparison (e.g. `./lib/foo.ex` -> `lib/foo.ex`).
  """
  @spec normalize_file_path(String.t()) :: String.t()
  def normalize_file_path(path) when is_binary(path) do
    path
    |> String.replace_prefix("./", "")
    |> relative_to_cwd()
  end

  def normalize_file_path(other), do: to_string(other)

  defp relative_to_cwd(path) do
    cwd = File.cwd!()
    expanded = Path.expand(path)

    if String.starts_with?(expanded, cwd) do
      expanded
      |> String.replace_prefix(cwd <> "/", "")
      |> String.replace_prefix(cwd, "")
    else
      path
    end
  end

  @doc """
  Normalizes rule names into clean snake_case strings for comparison.
  """
  @spec normalize_rule(term()) :: String.t() | nil
  def normalize_rule(nil), do: nil
  def normalize_rule("*"), do: nil
  def normalize_rule("_"), do: nil

  def normalize_rule(rule) when is_atom(rule) do
    rule
    |> Atom.to_string()
    |> normalize_rule()
  end

  def normalize_rule(rule) when is_binary(rule) do
    if String.contains?(rule, ".") do
      rule
      |> String.split(".")
      |> List.last()
      |> Macro.underscore()
    else
      Macro.underscore(rule)
    end
  end

  def normalize_rule(_), do: nil

  @doc """
  Checks if a finding with (file, line, rule) is excluded by any rule in `exclusions`.
  """
  @spec excluded?(String.t() | nil, integer() | nil, term(), [Exclusion.t()]) :: boolean()
  def excluded?(_file, _line, _rule, []), do: false

  def excluded?(file, line, rule, exclusions) when is_list(exclusions) do
    norm_file = if file, do: normalize_file_path(to_string(file)), else: ""
    norm_rule = normalize_rule(rule)

    Enum.any?(exclusions, fn %Exclusion{} = exc ->
      file_matches?(norm_file, exc.file) and
        line_matches?(line, exc.line) and
        rule_matches?(norm_rule, exc.rule)
    end)
  end

  defp file_matches?("", _exc_file), do: false
  defp file_matches?(_norm_file, nil), do: true

  defp file_matches?(norm_file, exc_file) do
    norm_file == exc_file or
      String.ends_with?(norm_file, "/" <> exc_file) or
      String.ends_with?(exc_file, "/" <> norm_file) or
      match_glob?(norm_file, exc_file)
  end

  defp match_glob?(norm_file, exc_file) do
    if String.contains?(exc_file, "*") do
      Regex.match?(glob_to_regex(exc_file), norm_file)
    else
      false
    end
  end

  defp glob_to_regex(glob) do
    escaped =
      glob
      |> Regex.escape()
      |> String.replace("\\*", ".*")

    Regex.compile!("^" <> escaped <> "$")
  end

  defp line_matches?(_line, nil), do: true
  defp line_matches?(nil, _exc_line), do: false

  defp line_matches?(line, exc_line) when is_integer(line) and is_integer(exc_line) do
    line == exc_line
  end

  defp line_matches?(_, _), do: false

  defp rule_matches?(_rule, nil), do: true
  defp rule_matches?(nil, _exc_rule), do: false

  defp rule_matches?(norm_rule, exc_rule) when is_binary(norm_rule) and is_binary(exc_rule) do
    norm_rule == exc_rule or
      String.contains?(norm_rule, exc_rule) or
      String.contains?(exc_rule, norm_rule)
  end

  defp rule_matches?(_, _), do: false

  @doc """
  Filters `results` map from `Runner.run_all/2` removing any excluded findings.
  """
  @spec filter_results(map(), [Exclusion.t()]) :: map()
  def filter_results(results, []) when is_map(results), do: results

  def filter_results(results, exclusions) when is_map(results) and is_list(exclusions) do
    Map.new(results, fn {type, data} ->
      {type, filter_type_results(type, data, exclusions)}
    end)
  end

  defp filter_type_results(:security, %{issues: issues} = data, exclusions) do
    filtered_issues =
      Enum.reject(issues, fn issue ->
        file = Map.get(issue, :file) || get_in(issue, [:location, :file])
        line = Map.get(issue, :line) || get_in(issue, [:location, :line])
        rule = Map.get(issue, :cwe) || Map.get(issue, :category) || Map.get(issue, :analyzer) || Map.get(issue, :check)

        excluded?(file, line, rule, exclusions)
      end)

    filtered_issues =
      Enum.map(filtered_issues, fn
        %{vulnerabilities: vulns} = issue when is_list(vulns) ->
          filtered_vulns =
            Enum.reject(vulns, fn v ->
              file = Map.get(v, :file) || get_in(v, [:location, :file])
              line = Map.get(v, :line) || get_in(v, [:location, :line])
              rule = Map.get(v, :cwe) || Map.get(v, :category) || Map.get(v, :analyzer) || Map.get(v, :check)

              excluded?(file, line, rule, exclusions)
            end)

          %{issue | vulnerabilities: filtered_vulns, has_vulnerabilities?: not Enum.empty?(filtered_vulns)}

        other ->
          other
      end)

    %{data | issues: filtered_issues}
  end

  defp filter_type_results(:business_logic, %{results: file_results} = data, exclusions) do
    filtered_file_results =
      Enum.map(file_results, fn file_res ->
        issues = Map.get(file_res, :issues, [])

        filtered_issues =
          Enum.reject(issues, fn issue ->
            file = Map.get(issue, :file) || Map.get(file_res, :file)
            line = Map.get(issue, :line) || get_in(issue, [:location, :line])
            rule = Map.get(issue, :analyzer) || Map.get(issue, :category)

            excluded?(file, line, rule, exclusions)
          end)

        %{file_res | issues: filtered_issues, has_issues?: not Enum.empty?(filtered_issues)}
      end)

    total = Enum.reduce(filtered_file_results, 0, fn r, acc -> acc + length(r.issues) end)
    files_with_issues = Enum.count(filtered_file_results, fn r -> r.has_issues? end)

    %{data | results: filtered_file_results, total_issues: total, files_with_issues: files_with_issues}
  end

  defp filter_type_results(:smells, %{smells: smells_data} = data, exclusions) do
    case smells_data do
      %{results: file_results} = map when is_list(file_results) ->
        filtered_file_results =
          Enum.map(file_results, fn file_res ->
            file_path = Map.get(file_res, :path) || Map.get(file_res, :file)
            smells = Map.get(file_res, :smells, [])

            filtered_smells =
              Enum.reject(smells, fn smell ->
                file = Map.get(smell, :file) || get_in(smell, [:location, :file]) || file_path
                line = Map.get(smell, :line) || get_in(smell, [:location, :line])
                rule = Map.get(smell, :type) || Map.get(smell, :check)

                excluded?(file, line, rule, exclusions)
              end)

            %{file_res | smells: filtered_smells, total_smells: length(filtered_smells), has_smells?: not Enum.empty?(filtered_smells)}
          end)

        total = Enum.reduce(filtered_file_results, 0, fn r, acc -> acc + length(r.smells) end)

        %{data | smells: %{map | results: filtered_file_results, total_smells: total}}

      list when is_list(list) ->
        filtered =
          Enum.reject(list, fn smell ->
            file = Map.get(smell, :file) || get_in(smell, [:location, :file])
            line = Map.get(smell, :line) || get_in(smell, [:location, :line])
            rule = Map.get(smell, :type) || Map.get(smell, :check)

            excluded?(file, line, rule, exclusions)
          end)

        %{data | smells: filtered}

      _ ->
        data
    end
  end

  defp filter_type_results(:complexity, %{complex_functions: funcs} = data, exclusions) do
    filtered =
      Enum.reject(funcs, fn f ->
        file = Map.get(f, :file) || Map.get(f, :path) || get_in(f, [:metadata, :file])
        line = Map.get(f, :line) || get_in(f, [:metadata, :line])
        rule = "long_function"

        excluded?(file, line, "cyclomatic_complexity", exclusions) or
          excluded?(file, line, "complexity", exclusions) or
          excluded?(file, line, rule, exclusions)
      end)

    %{data | complex_functions: filtered}
  end

  defp filter_type_results(:dead_code, %{dead_functions: funcs} = data, exclusions) do
    filtered =
      Enum.reject(funcs, fn f ->
        file = Map.get(f, :file) || Map.get(f, :path) || get_in(f, [:metadata, :file])
        line = Map.get(f, :line) || get_in(f, [:metadata, :line])

        excluded?(file, line, "dead_code", exclusions) or
          excluded?(file, line, "unused_function", exclusions)
      end)

    %{data | dead_functions: filtered}
  end

  defp filter_type_results(_type, data, _exclusions), do: data
end
