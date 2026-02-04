#!/usr/bin/env elixir

# Integration test for JSON cleanup in business logic directory analysis

# Start the application
Mix.start()
Mix.Task.run("app.start")

alias Ragex.Analysis.BusinessLogic

# Create temp test files
tmp_dir = "/tmp/ragex_json_cleanup_test_#{:rand.uniform(1000000)}"
File.mkdir_p!(tmp_dir)

# Create a clean file (no issues)
clean_file = Path.join(tmp_dir, "clean.ex")

File.write!(clean_file, """
defmodule Clean do
  def hello(name) do
    "Hello, \#{name}!"
  end
end
""")

# Analyze the directory
{:ok, dir_result} = BusinessLogic.analyze_directory(tmp_dir, analyzers: :all, min_severity: :info)

IO.puts("\n=== DIRECTORY RESULT STRUCTURE ===")
IO.inspect(dir_result, pretty: true, limit: :infinity)

IO.puts("\n=== FILE RESULTS (should be cleaned) ===")
Enum.each(dir_result.results, fn file_result ->
  IO.puts("\nFile: #{file_result.file}")
  IO.puts("Keys present: #{inspect(Map.keys(file_result))}")
  IO.puts("has_issues?: #{Map.get(file_result, :has_issues?, :not_present)}")
  IO.puts("total_issues: #{Map.get(file_result, :total_issues, :not_present)}")
  IO.puts("critical_count: #{Map.get(file_result, :critical_count, :not_present)}")
  IO.puts("issues: #{inspect(Map.get(file_result, :issues, :not_present))}")
end)

# Now simulate what format_bl_json does
defmodule JsonCleanupHelper do
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

IO.puts("\n=== AFTER CLEANUP (simulating format_bl_json) ===")
cleaned_dir_result = JsonCleanupHelper.cleanup(dir_result)

IO.puts("\nCleaned directory result keys: #{inspect(Map.keys(cleaned_dir_result))}")

if cleaned_dir_result[:results] do
  IO.puts("\n=== CLEANED FILE RESULTS ===")
  Enum.each(cleaned_dir_result.results, fn file_result ->
    IO.puts("\nFile: #{Map.get(file_result, :file, :not_present)}")
    IO.puts("Keys present: #{inspect(Map.keys(file_result))}")
    IO.puts("Has has_issues? key: #{Map.has_key?(file_result, :has_issues?)}")
    IO.puts("Has total_issues key: #{Map.has_key?(file_result, :total_issues)}")
    IO.puts("Has critical_count key: #{Map.has_key?(file_result, :critical_count)}")
    IO.puts("Has issues key: #{Map.has_key?(file_result, :issues)}")
  end)
end

# Cleanup
File.rm_rf!(tmp_dir)

IO.puts("\n=== TEST COMPLETE ===")

if Enum.any?(cleaned_dir_result.results, fn r ->
     Map.has_key?(r, :has_issues?) or Map.has_key?(r, :total_issues) or
       Map.has_key?(r, :critical_count) or Map.has_key?(r, :issues)
   end) do
  IO.puts("FAIL: Cleaned results still contain unwanted keys!")
  System.halt(1)
else
  IO.puts("PASS: All unwanted keys removed from file results!")
  System.halt(0)
end
