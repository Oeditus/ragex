defmodule Ragex.Editor.Preview do
  @moduledoc """
  Preview mode for refactoring operations.

  Provides dry-run capabilities to see what changes would be made
  without actually modifying files.
  """

  alias Ragex.Editor.Diff

  @type preview_result :: %{
          operation: atom(),
          files: [file_preview()],
          stats: %{
            files_affected: non_neg_integer(),
            total_additions: non_neg_integer(),
            total_deletions: non_neg_integer()
          },
          warnings: [String.t()]
        }

  @type file_preview :: %{
          path: String.t(),
          diff: Diff.diff_result(),
          formatted_diff: String.t()
        }

  @doc """
  Generates a preview of changes for a refactoring operation.

  ## Parameters
  - `operation`: Operation name (e.g., :rename_function)
  - `changes`: Map of file_path => {old_content, new_content}
  - `opts`: Options
    - `:format` - Diff format (:unified, :side_by_side, :json, :html)
    - `:context_lines` - Context lines in diff (default: 3)

  ## Returns
  - `{:ok, preview_result}` with diffs for all affected files
  """
  @spec generate_preview(atom(), %{String.t() => {String.t(), String.t()}}, keyword()) ::
          {:ok, preview_result()}
  def generate_preview(operation, changes, opts \\ []) do
    format = Keyword.get(opts, :format, :unified)
    context = Keyword.get(opts, :context_lines, 3)

    file_previews =
      Enum.map(changes, fn {path, {old_content, new_content}} ->
        {:ok, diff} =
          Diff.generate_diff(old_content, new_content,
            old_file: path,
            new_file: path,
            context_lines: context
          )

        {:ok, formatted} = Diff.format_diff(diff, format)

        %{
          path: path,
          diff: diff,
          formatted_diff: formatted
        }
      end)

    stats = calculate_preview_stats(file_previews)

    result = %{
      operation: operation,
      files: file_previews,
      stats: stats,
      warnings: []
    }

    {:ok, result}
  end

  defp calculate_preview_stats(file_previews) do
    Enum.reduce(
      file_previews,
      %{files_affected: 0, total_additions: 0, total_deletions: 0},
      fn preview, acc ->
        %{
          files_affected: acc.files_affected + 1,
          total_additions: acc.total_additions + preview.diff.stats.additions,
          total_deletions: acc.total_deletions + preview.diff.stats.deletions
        }
      end
    )
  end
end
