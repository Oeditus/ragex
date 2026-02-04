#!/usr/bin/env elixir

# Demo script showing JSON cleanup behavior for analysis results

# Simulated analysis result with no issues
no_issues_data = %{
  status: "success",
  scan_type: "file",
  path: "lib/clean_file.ex",
  language: :elixir,
  has_issues?: false,
  has_smells?: false,
  total_issues: 0,
  total_smells: 0,
  critical_count: 0,
  high_count: 0,
  medium_count: 0,
  low_count: 0,
  info_count: 0,
  by_severity: %{},
  by_analyzer: %{},
  issues: [],
  smells: [],
  files_with_issues: 0,
  files_with_smells: 0,
  summary: "No issues detected"
}

# Simulated analysis result with some issues
with_issues_data = %{
  status: "success",
  scan_type: "file",
  path: "lib/problematic_file.ex",
  language: :elixir,
  has_issues?: true,
  has_smells?: true,
  total_issues: 5,
  total_smells: 3,
  critical_count: 1,
  high_count: 2,
  medium_count: 0,
  low_count: 2,
  info_count: 0,
  by_severity: %{critical: 1, high: 2, low: 2},
  by_analyzer: %{callback_hell: 2, missing_error_handling: 3},
  issues: [
    %{type: :callback_hell, severity: :high},
    %{type: :missing_error_handling, severity: :critical}
  ],
  smells: [
    %{type: :long_function, severity: :medium}
  ],
  files_with_issues: 1,
  files_with_smells: 1,
  summary: "Found 5 issues and 3 code smells"
}

# Cleanup function
defmodule JsonCleanup do
  def cleanup(data) when is_struct(data) do
    # Don't try to clean structs - return as-is
    data
  end

  def cleanup(data) when is_map(data) do
    data
    |> Enum.reject(fn
      {key, false} when is_atom(key) ->
        key_str = Atom.to_string(key)
        String.starts_with?(key_str, "has_") && String.ends_with?(key_str, "?")

      {_key, value} when is_list(value) -> Enum.empty?(value)
      {_key, value} when is_map(value) and not is_struct(value) -> map_size(value) == 0

      {key, 0} when is_atom(key) ->
        key in [
          :critical_count,
          :high_count,
          :medium_count,
          :low_count,
          :info_count,
          :total_smells,
          :total_issues,
          :files_with_smells,
          :files_with_issues
        ]

      _ ->
        false
    end)
    |> Enum.map(fn
      {key, value} when is_struct(value) -> {key, value}
      {key, value} when is_map(value) -> {key, cleanup(value)}
      {key, values} when is_list(values) -> {key, Enum.map(values, &cleanup/1)}
      other -> other
    end)
    |> Map.new()
  end

  def cleanup(data) when is_list(data) do
    Enum.map(data, &cleanup/1)
  end

  def cleanup(data), do: data
end

IO.puts("\n=== BEFORE CLEANUP (No Issues) ===")
IO.inspect(no_issues_data, pretty: true, limit: :infinity, width: 80)

IO.puts("\n=== AFTER CLEANUP (No Issues) ===")
cleaned_no_issues = JsonCleanup.cleanup(no_issues_data)
IO.inspect(cleaned_no_issues, pretty: true, limit: :infinity, width: 80)

IO.puts("\n=== BEFORE CLEANUP (With Issues) ===")
IO.inspect(with_issues_data, pretty: true, limit: :infinity, width: 80)

IO.puts("\n=== AFTER CLEANUP (With Issues) ===")
cleaned_with_issues = JsonCleanup.cleanup(with_issues_data)
IO.inspect(cleaned_with_issues, pretty: true, limit: :infinity, width: 80)

IO.puts("\n=== COMPARISON ===")
IO.puts("Original no-issues keys: #{Enum.count(no_issues_data)}")
IO.puts("Cleaned no-issues keys: #{Enum.count(cleaned_no_issues)}")
IO.puts("Reduction: #{Enum.count(no_issues_data) - Enum.count(cleaned_no_issues)} keys removed")

IO.puts("\nOriginal with-issues keys: #{Enum.count(with_issues_data)}")
IO.puts("Cleaned with-issues keys: #{Enum.count(cleaned_with_issues)}")
IO.puts("Reduction: #{Enum.count(with_issues_data) - Enum.count(cleaned_with_issues)} keys removed")
