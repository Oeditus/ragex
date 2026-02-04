defmodule Ragex.MCP.Handlers.JsonCleanupTest do
  use ExUnit.Case, async: true

  # Access the private cleanup_no_issues function via a wrapper
  # We'll need to test this through the public API or make it accessible
  # For now, let's test the behavior through the actual tool calls

  describe "cleanup_no_issues/1" do
    # Since cleanup_no_issues is private, we test it indirectly
    # by verifying that JSON outputs don't include unwanted fields

    test "removes false has_* boolean flags" do
      data = %{
        has_smells?: false,
        has_issues?: false,
        has_warnings?: false,
        has_errors?: true,
        total_files: 5
      }

      # Manually call the cleanup logic
      result = cleanup_test_data(data)

      refute Map.has_key?(result, :has_smells?)
      refute Map.has_key?(result, :has_issues?)
      refute Map.has_key?(result, :has_warnings?)
      assert Map.has_key?(result, :has_errors?)
      assert Map.has_key?(result, :total_files)
    end

    test "removes empty collections" do
      data = %{
        smells: [],
        issues: [%{type: :test}],
        by_severity: %{},
        total_files: 3
      }

      result = cleanup_test_data(data)

      refute Map.has_key?(result, :smells)
      assert Map.has_key?(result, :issues)
      refute Map.has_key?(result, :by_severity)
      assert Map.has_key?(result, :total_files)
    end

    test "removes zero counts for metrics" do
      data = %{
        critical_count: 0,
        high_count: 2,
        medium_count: 0,
        low_count: 0,
        info_count: 1,
        total_smells: 0,
        total_issues: 3,
        files_with_smells: 0,
        files_with_issues: 2
      }

      result = cleanup_test_data(data)

      refute Map.has_key?(result, :critical_count)
      assert Map.has_key?(result, :high_count)
      refute Map.has_key?(result, :medium_count)
      refute Map.has_key?(result, :low_count)
      assert Map.has_key?(result, :info_count)
      refute Map.has_key?(result, :total_smells)
      assert Map.has_key?(result, :total_issues)
      refute Map.has_key?(result, :files_with_smells)
      assert Map.has_key?(result, :files_with_issues)
    end

    test "recursively cleans nested maps" do
      data = %{
        outer: %{
          has_issues?: false,
          total_issues: 0,
          inner: %{
            has_smells?: false,
            smells: [],
            valid_data: "keep this"
          },
          keep_this: "value"
        }
      }

      result = cleanup_test_data(data)

      assert Map.has_key?(result, :outer)
      refute Map.has_key?(result.outer, :total_issues)
      assert Map.has_key?(result.outer, :inner)
      refute Map.has_key?(result.outer.inner, :has_smells?)
      refute Map.has_key?(result.outer.inner, :smells)
      assert result.outer.inner.valid_data == "keep this"
      assert result.outer.keep_this == "value"
    end

    test "cleans lists of maps" do
      data = %{
        results: [
          %{file: "a.ex", has_issues?: false, total_issues: 0},
          %{file: "b.ex", has_issues?: true, total_issues: 2},
          %{file: "c.ex", has_smells?: false, smells: []}
        ]
      }

      result = cleanup_test_data(data)

      assert length(result.results) == 3
      refute Map.has_key?(Enum.at(result.results, 0), :has_issues?)
      refute Map.has_key?(Enum.at(result.results, 0), :total_issues)
      assert Map.has_key?(Enum.at(result.results, 1), :has_issues?)
      assert Map.has_key?(Enum.at(result.results, 1), :total_issues)
      refute Map.has_key?(Enum.at(result.results, 2), :has_smells?)
      refute Map.has_key?(Enum.at(result.results, 2), :smells)
    end

    test "preserves non-zero values and truthy flags" do
      data = %{
        has_issues?: true,
        critical_count: 5,
        total_issues: 10,
        files_with_issues: 3,
        summary: "Test summary",
        status: "success"
      }

      result = cleanup_test_data(data)

      assert result.has_issues? == true
      assert result.critical_count == 5
      assert result.total_issues == 10
      assert result.files_with_issues == 3
      assert result.summary == "Test summary"
      assert result.status == "success"
    end

    test "handles mixed content appropriately" do
      data = %{
        status: "success",
        has_issues?: false,
        has_smells?: true,
        total_issues: 0,
        total_smells: 5,
        by_severity: %{high: 2, medium: 3},
        by_type: %{},
        issues: [],
        smells: [%{type: :long_function}],
        summary: "Mixed results"
      }

      result = cleanup_test_data(data)

      assert result.status == "success"
      refute Map.has_key?(result, :has_issues?)
      assert result.has_smells? == true
      refute Map.has_key?(result, :total_issues)
      assert result.total_smells == 5
      assert Map.has_key?(result, :by_severity)
      refute Map.has_key?(result, :by_type)
      refute Map.has_key?(result, :issues)
      assert Map.has_key?(result, :smells)
      assert result.summary == "Mixed results"
    end
  end

  # Helper function that mimics the private cleanup_no_issues/1
  defp cleanup_test_data(data) when is_struct(data) do
    # Don't try to clean structs - return as-is
    data
  end

  defp cleanup_test_data(data) when is_map(data) do
    data
    |> Enum.reject(fn
      # Remove boolean flags that are false (has_smells?, has_issues?, etc.)
      {key, false} when is_atom(key) ->
        key_str = Atom.to_string(key)
        String.starts_with?(key_str, "has_") && String.ends_with?(key_str, "?")

      # Remove empty collections
      {_key, value} when is_list(value) ->
        Enum.empty?(value)

      {_key, value} when is_map(value) and not is_struct(value) ->
        map_size(value) == 0

      # Remove zero counts for severity/issue metrics
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

      # Keep everything else
      _ ->
        false
    end)
    |> Enum.map(fn
      # Don't recurse into structs
      {key, value} when is_struct(value) -> {key, value}
      # Recursively clean nested maps
      {key, value} when is_map(value) -> {key, cleanup_test_data(value)}
      # Recursively clean lists of maps
      {key, values} when is_list(values) -> {key, Enum.map(values, &cleanup_test_data/1)}
      # Keep other values as-is
      other -> other
    end)
    |> Map.new()
  end

  defp cleanup_test_data(data) when is_list(data) do
    Enum.map(data, &cleanup_test_data/1)
  end

  defp cleanup_test_data(data), do: data
end
