#!/usr/bin/env elixir

# Test script for smell detection JSON cleanup

Mix.start()
Mix.Task.run("app.start")

alias Ragex.Analysis.Smells

# Create temp test files
tmp_dir = "/tmp/ragex_smells_cleanup_test_#{:rand.uniform(1000000)}"
File.mkdir_p!(tmp_dir)

# Create a clean file (no smells)
clean_file = Path.join(tmp_dir, "clean.ex")

File.write!(clean_file, """
defmodule Clean do
  def hello(name) do
    "Hello, \#{name}!"
  end
end
""")

# Analyze the directory
{:ok, dir_result} = Smells.analyze_directory(tmp_dir, recursive: true, min_severity: :low)

IO.puts("\n=== DIRECTORY RESULT ===")
IO.puts("Total files: #{dir_result.total_files}")
IO.puts("Files with smells: #{dir_result.files_with_smells}")
IO.puts("Total smells: #{dir_result.total_smells}")

IO.puts("\n=== FILE RESULTS (before cleanup) ===")
Enum.each(dir_result.results, fn file_result ->
  IO.puts("\nFile: #{file_result.path}")
  IO.puts("Keys: #{inspect(Map.keys(file_result))}")
  IO.puts("has_smells?: #{file_result.has_smells?}")
  IO.puts("total_smells: #{file_result.total_smells}")
  IO.puts("by_severity: #{inspect(file_result.by_severity)}")
  IO.puts("by_type: #{inspect(file_result.by_type)}")
  IO.puts("smells: #{inspect(file_result.smells)}")
end)

# Simulate cleanup via MCP handler
defmodule CleanupHelper do
  def cleanup(data) when is_struct(data), do: data

  def cleanup(data) when is_map(data) do
    data
    |> Enum.reject(fn
      {key, false} when is_atom(key) ->
        key_str = Atom.to_string(key)
        String.starts_with?(key_str, "has_") && String.ends_with?(key_str, "?")

      {_key, value} when is_list(value) ->
        Enum.empty?(value)

      {_key, value} when is_map(value) and not is_struct(value) ->
        map_size(value) == 0

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

  def cleanup(data) when is_list(data), do: Enum.map(data, &cleanup/1)
  def cleanup(data), do: data
end

IO.puts("\n=== FILE RESULTS (after cleanup) ===")
cleaned_results = Enum.map(dir_result.results, &CleanupHelper.cleanup/1)

Enum.each(cleaned_results, fn file_result ->
  IO.puts("\nFile: #{Map.get(file_result, :path, :not_found)}")
  IO.puts("Keys: #{inspect(Map.keys(file_result))}")
  IO.puts("Has has_smells?: #{Map.has_key?(file_result, :has_smells?)}")
  IO.puts("Has total_smells: #{Map.has_key?(file_result, :total_smells)}")
  IO.puts("Has by_severity: #{Map.has_key?(file_result, :by_severity)}")
  IO.puts("Has by_type: #{Map.has_key?(file_result, :by_type)}")
  IO.puts("Has smells: #{Map.has_key?(file_result, :smells)}")
end)

# Cleanup
File.rm_rf!(tmp_dir)

IO.puts("\n=== TEST COMPLETE ===")

if Enum.any?(cleaned_results, fn r ->
     Map.has_key?(r, :has_smells?) or Map.has_key?(r, :total_smells) or
       Map.has_key?(r, :by_severity) or Map.has_key?(r, :by_type) or
       Map.has_key?(r, :smells)
   end) do
  IO.puts("FAIL: Cleaned results still contain unwanted keys!")
  System.halt(1)
else
  IO.puts("PASS: All unwanted keys removed from file results!")
  System.halt(0)
end
