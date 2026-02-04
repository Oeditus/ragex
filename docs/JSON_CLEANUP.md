# JSON Output Cleanup

## Overview

Ragex automatically cleans up JSON output from analysis tools to suppress "no issue" indicators and reduce noise in the response. This makes the JSON more readable and focused on actual findings.

## What Gets Removed

The cleanup function removes the following types of fields when they indicate "no issues":

### 1. False Boolean Flags

All boolean fields following the pattern `has_*?` are removed when they are `false`:
- `has_smells?: false` → removed
- `has_issues?: false` → removed
- `has_warnings?: false` → removed

When `true`, they are kept:
- `has_issues?: true` → kept

### 2. Zero Count Metrics

Severity and issue count fields are removed when they are `0`:
- `critical_count: 0` → removed
- `high_count: 0` → removed
- `medium_count: 0` → removed
- `low_count: 0` → removed
- `info_count: 0` → removed
- `total_smells: 0` → removed
- `total_issues: 0` → removed
- `files_with_smells: 0` → removed
- `files_with_issues: 0` → removed

Non-zero counts are kept:
- `high_count: 2` → kept

### 3. Empty Collections

Empty lists and maps are removed:
- `issues: []` → removed
- `smells: []` → removed
- `by_severity: %{}` → removed
- `by_analyzer: %{}` → removed

Non-empty collections are kept:
- `issues: [...]` → kept

## Recursive Cleanup

The cleanup is applied recursively to:
- Nested maps
- Lists of maps
- All levels of the response structure

**Note**: Structs (like `DateTime`, `Date`, etc.) are preserved as-is and not recursively cleaned, as they have special semantics that should not be modified.

## Example

### Before Cleanup (Clean File)
```json
{
  "status": "success",
  "scan_type": "file",
  "path": "lib/clean_file.ex",
  "language": "elixir",
  "has_issues?": false,
  "has_smells?": false,
  "total_issues": 0,
  "total_smells": 0,
  "critical_count": 0,
  "high_count": 0,
  "medium_count": 0,
  "low_count": 0,
  "info_count": 0,
  "by_severity": {},
  "by_analyzer": {},
  "issues": [],
  "smells": [],
  "files_with_issues": 0,
  "files_with_smells": 0,
  "summary": "No issues detected"
}
```

### After Cleanup (Clean File)
```json
{
  "status": "success",
  "scan_type": "file",
  "path": "lib/clean_file.ex",
  "language": "elixir",
  "summary": "No issues detected"
}
```

**Result**: 15 keys removed (75% reduction)

### Before Cleanup (File with Issues)
```json
{
  "status": "success",
  "scan_type": "file",
  "path": "lib/problematic_file.ex",
  "language": "elixir",
  "has_issues?": true,
  "has_smells?": true,
  "total_issues": 5,
  "total_smells": 3,
  "critical_count": 1,
  "high_count": 2,
  "medium_count": 0,
  "low_count": 2,
  "info_count": 0,
  "by_severity": {"critical": 1, "high": 2, "low": 2},
  "by_analyzer": {"callback_hell": 2, "missing_error_handling": 3},
  "issues": [...],
  "smells": [...],
  "files_with_issues": 1,
  "files_with_smells": 1,
  "summary": "Found 5 issues and 3 code smells"
}
```

### After Cleanup (File with Issues)
```json
{
  "status": "success",
  "scan_type": "file",
  "path": "lib/problematic_file.ex",
  "language": "elixir",
  "has_issues?": true,
  "has_smells?": true,
  "total_issues": 5,
  "total_smells": 3,
  "critical_count": 1,
  "high_count": 2,
  "low_count": 2,
  "by_severity": {"critical": 1, "high": 2, "low": 2},
  "by_analyzer": {"callback_hell": 2, "missing_error_handling": 3},
  "issues": [...],
  "smells": [...],
  "files_with_issues": 1,
  "files_with_smells": 1,
  "summary": "Found 5 issues and 3 code smells"
}
```

**Result**: 2 keys removed (only zero-value fields)

## Results Array Filtering

In addition to cleaning individual fields, the cleanup process also **filters out entire file results** from the `results` array when they have:
- No issues/smells (`has_issues?: false` or `has_smells?: false`)
- AND no errors

This means the `results` array will only contain files that either:
- Have issues/smells to report
- OR had errors during analysis

Files with clean analysis (no issues and no errors) are completely removed from the results array, making the output much more focused on actionable items.

## Affected MCP Tools

The cleanup is automatically applied to JSON output from:

1. **Business Logic Analysis**
   - `analyze_business_logic` (all formats: json, summary, detailed)
   - File results with no issues are filtered from `results` array

2. **Code Smells Analysis**
   - `detect_smells` (all scan types: file, directory)
   - File results with no smells are filtered from `results` array

## Implementation

The cleanup is implemented in `/lib/ragex/mcp/handlers/tools.ex`:

```elixir
defp cleanup_no_issues(data) when is_map(data) do
  data
  |> Enum.reject(fn
    # Remove false has_* flags
    {key, false} when is_atom(key) ->
      key_str = Atom.to_string(key)
      String.starts_with?(key_str, "has_") && String.ends_with?(key_str, "?")

    # Remove empty collections
    {_key, value} when is_list(value) -> Enum.empty?(value)
    {_key, value} when is_map(value) -> map_size(value) == 0

    # Remove zero counts
    {key, 0} when is_atom(key) ->
      key in [:critical_count, :high_count, ...]

    _ -> false
  end)
  |> Enum.map(fn
    {key, value} when is_map(value) -> {key, cleanup_no_issues(value)}
    {key, values} when is_list(values) -> {key, Enum.map(values, &cleanup_no_issues/1)}
    other -> other
  end)
  |> Map.new()
end
```

## Benefits

1. **Reduced noise**: Only relevant information is shown
2. **Clearer intent**: Absence of fields indicates absence of issues
3. **Smaller payloads**: Less data to transmit and parse
4. **Better UX**: Easier to read and understand results
5. **Consistent**: Applied uniformly across all analysis tools

## Testing

Tests are located in `/test/mcp/handlers/json_cleanup_test.exs`:
- Tests for boolean flag removal
- Tests for empty collection removal
- Tests for zero count removal
- Tests for recursive cleanup
- Tests for preservation of meaningful data

Run tests:
```bash
mix test test/mcp/handlers/json_cleanup_test.exs
```

## Demo Script

A demonstration script is available at `/stuff/scripts/demo_json_cleanup.exs`:

```bash
elixir stuff/scripts/demo_json_cleanup.exs
```

This shows before/after comparisons for both clean and problematic files.
