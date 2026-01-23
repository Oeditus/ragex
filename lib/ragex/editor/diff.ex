defmodule Ragex.Editor.Diff do
  @moduledoc """
  Diff generation and formatting for refactoring operations.

  Provides multiple diff formats for previewing code changes:
  - Unified diff (Git-style)
  - Side-by-side diff
  - JSON structured diff
  - HTML diff (for web UIs)

  Uses Elixir's built-in Myers algorithm via `List.myers_difference/2`.
  """

  @type diff_format :: :unified | :side_by_side | :json | :html
  @type diff_line :: {:eq, String.t()} | {:del, String.t()} | {:ins, String.t()}
  @type diff_chunk :: %{
          old_start: pos_integer(),
          old_count: non_neg_integer(),
          new_start: pos_integer(),
          new_count: non_neg_integer(),
          lines: [diff_line()]
        }

  @type diff_result :: %{
          old_file: String.t(),
          new_file: String.t(),
          chunks: [diff_chunk()],
          stats: %{
            additions: non_neg_integer(),
            deletions: non_neg_integer(),
            changes: non_neg_integer()
          }
        }

  @doc """
  Generates a diff between original and modified content.

  ## Parameters
  - `old_content`: Original content as string
  - `new_content`: Modified content as string
  - `opts`: Options
    - `:context_lines` - Number of context lines (default: 3)
    - `:old_file` - Label for old file (default: "original")
    - `:new_file` - Label for new file (default: "modified")

  ## Returns
  - `{:ok, diff_result}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> Diff.generate_diff("line1\\nline2\\n", "line1\\nmodified\\n")
      {:ok, %{chunks: [%{old_start: 1, ...}], stats: %{...}}}
  """
  @spec generate_diff(String.t(), String.t(), keyword()) ::
          {:ok, diff_result()} | {:error, term()}
  def generate_diff(old_content, new_content, opts \\ []) do
    context_lines = Keyword.get(opts, :context_lines, 3)
    old_file = Keyword.get(opts, :old_file, "original")
    new_file = Keyword.get(opts, :new_file, "modified")

    # Handle empty content specially - String.split("", "\n") returns [""] not []
    old_lines = if old_content == "", do: [], else: String.split(old_content, "\n")
    new_lines = if new_content == "", do: [], else: String.split(new_content, "\n")

    # Use Myers algorithm to compute diff
    myers_diff = List.myers_difference(old_lines, new_lines)

    # Convert to our format and chunk by context
    chunks = build_chunks(myers_diff, context_lines)
    stats = calculate_stats(chunks)

    result = %{
      old_file: old_file,
      new_file: new_file,
      chunks: chunks,
      stats: stats
    }

    {:ok, result}
  rescue
    error -> {:error, "Failed to generate diff: #{inspect(error)}"}
  end

  @doc """
  Formats a diff result in the specified format.

  ## Parameters
  - `diff_result`: Result from `generate_diff/3`
  - `format`: One of `:unified`, `:side_by_side`, `:json`, `:html`
  - `opts`: Format-specific options

  ## Returns
  - `{:ok, formatted_string}` on success
  - `{:error, reason}` on failure
  """
  @spec format_diff(diff_result(), diff_format(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def format_diff(diff_result, format \\ :unified, opts \\ [])

  def format_diff(diff_result, :unified, _opts) do
    {:ok, format_unified(diff_result)}
  end

  def format_diff(diff_result, :side_by_side, opts) do
    width = Keyword.get(opts, :width, 120)
    {:ok, format_side_by_side(diff_result, width)}
  end

  def format_diff(diff_result, :json, _opts) do
    # Convert tuples to JSON-friendly format
    json_friendly = diff_result_to_json(diff_result)
    {:ok, Jason.encode!(json_friendly)}
  rescue
    error -> {:error, "Failed to encode JSON: #{inspect(error)}"}
  end

  def format_diff(diff_result, :html, _opts) do
    {:ok, format_html(diff_result)}
  end

  def format_diff(_diff_result, format, _opts) do
    {:error, "Unknown format: #{inspect(format)}"}
  end

  @doc """
  Applies a diff to content (reverse operation of generate_diff).

  ## Parameters
  - `original_content`: Original content
  - `diff_result`: Diff to apply

  ## Returns
  - `{:ok, new_content}` on success
  - `{:error, reason}` on failure
  """
  @spec apply_diff(String.t(), diff_result()) :: {:ok, String.t()} | {:error, term()}
  def apply_diff(original_content, diff_result) do
    old_lines = String.split(original_content, "\n")
    new_lines = apply_chunks(old_lines, diff_result.chunks)
    {:ok, Enum.join(new_lines, "\n")}
  rescue
    error -> {:error, "Failed to apply diff: #{inspect(error)}"}
  end

  # Private functions

  defp diff_result_to_json(diff_result) do
    # For JSON format, only include actual changes (not context lines)
    changes =
      Enum.flat_map(diff_result.chunks, fn chunk ->
        Enum.flat_map(chunk.lines, fn
          # Skip unchanged context lines
          {:eq, _line} -> []
          {:del, line} -> [%{type: "delete", content: line}]
          {:ins, line} -> [%{type: "insert", content: line}]
        end)
      end)

    %{
      old_file: diff_result.old_file,
      new_file: diff_result.new_file,
      stats: diff_result.stats,
      changes: changes
    }
  end

  defp build_chunks(myers_diff, context_lines) do
    # Convert Myers diff to line-based format with context
    lines = myers_to_lines(myers_diff)

    # Group into chunks separated by context
    chunk_lines(lines, context_lines)
  end

  defp myers_to_lines(myers_diff) do
    Enum.flat_map(myers_diff, fn
      {:eq, lines} -> Enum.map(lines, &{:eq, &1})
      {:del, lines} -> Enum.map(lines, &{:del, &1})
      {:ins, lines} -> Enum.map(lines, &{:ins, &1})
    end)
  end

  defp chunk_lines(lines, context_lines) do
    # Build list of all lines with indices
    indexed_lines = Enum.with_index(lines, 1)

    # Find indices of all changes
    change_indices =
      indexed_lines
      |> Enum.filter(fn {{type, _}, _idx} -> type in [:del, :ins] end)
      |> Enum.map(fn {_, idx} -> idx end)

    # If no changes, return empty chunks
    if Enum.empty?(change_indices) do
      []
    else
      # Group changes into ranges with context
      change_ranges = build_change_ranges(change_indices, context_lines, length(lines))

      # Convert ranges to chunks
      Enum.map(change_ranges, fn {range_start, range_end} ->
        chunk_lines = Enum.slice(indexed_lines, range_start - 1, range_end - range_start + 1)
        build_chunk_from_lines(chunk_lines)
      end)
    end
  end

  defp build_change_ranges(change_indices, context_lines, total_lines) do
    # Expand each change index to include context
    expanded_ranges =
      Enum.map(change_indices, fn idx ->
        range_start = max(1, idx - context_lines)
        range_end = min(total_lines, idx + context_lines)
        {range_start, range_end}
      end)

    # Merge overlapping ranges
    merge_ranges(expanded_ranges)
  end

  defp merge_ranges([]), do: []
  defp merge_ranges([range]), do: [range]

  defp merge_ranges(ranges) do
    [first | rest] = Enum.sort(ranges)

    {merged, current} =
      Enum.reduce(rest, {[], first}, fn {start, end_pos}, {acc, {curr_start, curr_end}} ->
        if start <= curr_end + 1 do
          # Overlapping or adjacent, merge
          {acc, {curr_start, max(end_pos, curr_end)}}
        else
          # Non-overlapping, finalize current and start new
          {[{curr_start, curr_end} | acc], {start, end_pos}}
        end
      end)

    Enum.reverse([current | merged])
  end

  defp build_chunk_from_lines(indexed_lines) do
    [{_, first_idx} | _] = indexed_lines
    lines = Enum.map(indexed_lines, fn {line, _} -> line end)

    {old_count, new_count} =
      Enum.reduce(lines, {0, 0}, fn
        {:eq, _}, {old, new} -> {old + 1, new + 1}
        {:del, _}, {old, new} -> {old + 1, new}
        {:ins, _}, {old, new} -> {old, new + 1}
      end)

    %{
      old_start: first_idx,
      old_count: old_count,
      new_start: first_idx,
      new_count: new_count,
      lines: lines
    }
  end

  defp calculate_stats(chunks) do
    Enum.reduce(chunks, %{additions: 0, deletions: 0, changes: 0}, fn chunk, stats ->
      chunk_stats =
        Enum.reduce(chunk.lines, %{additions: 0, deletions: 0}, fn
          {:ins, _}, acc -> %{acc | additions: acc.additions + 1}
          {:del, _}, acc -> %{acc | deletions: acc.deletions + 1}
          {:eq, _}, acc -> acc
        end)

      %{
        additions: stats.additions + chunk_stats.additions,
        deletions: stats.deletions + chunk_stats.deletions,
        changes: stats.changes + 1
      }
    end)
  end

  defp apply_chunks(old_lines, chunks) do
    Enum.reduce(chunks, old_lines, fn chunk, lines ->
      apply_single_chunk(lines, chunk)
    end)
  end

  defp apply_single_chunk(lines, chunk) do
    # Extract the changes from chunk
    changes =
      Enum.flat_map(chunk.lines, fn
        {:eq, line} -> [line]
        {:ins, line} -> [line]
        {:del, _} -> []
      end)

    # Replace lines in range
    {before, rest} = Enum.split(lines, chunk.old_start - 1)
    {_old, after_chunk} = Enum.split(rest, chunk.old_count)

    before ++ changes ++ after_chunk
  end

  # Format functions

  defp format_unified(diff_result) do
    header = """
    --- #{diff_result.old_file}
    +++ #{diff_result.new_file}
    """

    chunks_str =
      Enum.map_join(diff_result.chunks, "\n", fn chunk ->
        format_unified_chunk(chunk)
      end)

    header <> chunks_str
  end

  defp format_unified_chunk(chunk) do
    header =
      "@@ -#{chunk.old_start},#{chunk.old_count} +#{chunk.new_start},#{chunk.new_count} @@\n"

    lines =
      Enum.map_join(chunk.lines, "\n", fn
        {:eq, line} -> " #{line}"
        {:del, line} -> "-#{line}"
        {:ins, line} -> "+#{line}"
      end)

    header <> lines
  end

  defp format_side_by_side(diff_result, width) do
    half_width = div(width - 3, 2)

    header = """
    #{String.pad_trailing(diff_result.old_file, half_width)} | #{diff_result.new_file}
    #{String.duplicate("-", width)}
    """

    chunks_str =
      Enum.map_join(diff_result.chunks, "\n", fn chunk ->
        format_side_by_side_chunk(chunk, half_width)
      end)

    header <> chunks_str
  end

  defp format_side_by_side_chunk(chunk, half_width) do
    Enum.map_join(chunk.lines, "\n", fn
      {:eq, line} ->
        left = String.pad_trailing(truncate(line, half_width), half_width)
        right = truncate(line, half_width)
        "#{left} | #{right}"

      {:del, line} ->
        left = String.pad_trailing(truncate(line, half_width), half_width)
        "#{left} < "

      {:ins, line} ->
        left = String.pad_trailing("", half_width)
        right = truncate(line, half_width)
        "#{left} > #{right}"
    end)
  end

  defp truncate(str, max_len) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len - 3) <> "..."
    else
      str
    end
  end

  defp format_html(diff_result) do
    """
    <div class="diff">
      <div class="diff-header">
        <span class="old-file">#{escape_html(diff_result.old_file)}</span>
        →
        <span class="new-file">#{escape_html(diff_result.new_file)}</span>
      </div>
      #{Enum.map_join(diff_result.chunks, "", &format_html_chunk/1)}
      <div class="diff-stats">
        <span class="additions">+#{diff_result.stats.additions}</span>
        <span class="deletions">-#{diff_result.stats.deletions}</span>
      </div>
    </div>
    """
  end

  defp format_html_chunk(chunk) do
    """
    <div class="diff-chunk">
      <div class="chunk-header">
        @@ -#{chunk.old_start},#{chunk.old_count} +#{chunk.new_start},#{chunk.new_count} @@
      </div>
      <pre class="chunk-lines">
    #{Enum.map_join(chunk.lines, "", &format_html_line/1)}
      </pre>
    </div>
    """
  end

  defp format_html_line({:eq, line}) do
    "<span class=\"line eq\"> #{escape_html(line)}</span>\n"
  end

  defp format_html_line({:del, line}) do
    "<span class=\"line del\">-#{escape_html(line)}</span>\n"
  end

  defp format_html_line({:ins, line}) do
    "<span class=\"line ins\">+#{escape_html(line)}</span>\n"
  end

  defp escape_html(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # Wrapper functions for test compatibility

  @doc """
  Combined generate and format function for test compatibility.

  Generates a diff and returns it in a format suitable for testing.
  """
  def generate(old_content, new_content, file_path, opts \\ []) do
    format = Keyword.get(opts, :format, :unified)
    context_lines = Keyword.get(opts, :context_lines, 3)

    diff_opts = [
      old_file: file_path,
      new_file: file_path,
      context_lines: context_lines
    ]

    with {:ok, diff_result} <- generate_diff(old_content, new_content, diff_opts) do
      # Calculate unchanged count: total lines in old - deletions
      old_lines_count =
        if old_content == "",
          do: 0,
          else: length(String.split(old_content, "\n"))

      unchanged = old_lines_count - diff_result.stats.deletions

      # Build result structure matching test expectations
      result = %{
        file_path: file_path,
        format: format,
        stats: %{
          added: diff_result.stats.additions,
          removed: diff_result.stats.deletions,
          unchanged: unchanged
        }
      }

      # Add format-specific fields
      result =
        case format do
          :unified ->
            {:ok, formatted} = format_diff(diff_result, :unified)
            Map.put(result, :unified_diff, formatted)

          :side_by_side ->
            {:ok, formatted} = format_diff(diff_result, :side_by_side)
            Map.put(result, :side_by_side_diff, formatted)

          :json ->
            {:ok, formatted} = format_diff(diff_result, :json)
            json_data = Jason.decode!(formatted, keys: :atoms)
            Map.put(result, :json_diff, json_data)

          :html ->
            {:ok, formatted} = format_diff(diff_result, :html)
            Map.put(result, :html_diff, formatted)

          _ ->
            result
        end

      {:ok, result}
    end
  end

  @doc """
  Compares two files and returns a diff.
  """
  def compare_files(file1, file2, opts \\ []) do
    with {:ok, content1} <- File.read(file1),
         {:ok, content2} <- File.read(file2) do
      format = Keyword.get(opts, :format, :unified)
      generate(content1, content2, file2, format: format)
    end
  end
end
