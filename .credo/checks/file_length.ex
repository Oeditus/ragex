defmodule Ragex.Credo.Check.FileLength do
  @moduledoc false

  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [
      max_lines: 1000,
      exit_status: 0
    ],
    explanations: [
      check: """
      Files that grow past a reasonable size are a strong signal that a
      module is taking on too many responsibilities and should be split.

      `lib/ragex/mcp/handlers/tools.ex` grew to over 9,000 lines while a
      dedicated plugin architecture (`Ragex.Plugin`) was being built
      specifically to decompose it, because nothing enforced a budget on
      individual file size. This check exists to catch the next one early.

      Staged as `exit_status: 0` (visible, non-blocking) until the existing
      backlog of oversized files is worked down; flip to a normal exit
      status once the codebase is under budget everywhere.
      """,
      params: [
        max_lines: "The maximum number of lines allowed in a single file."
      ]
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    max_lines = Params.get(params, :max_lines, __MODULE__)

    line_count =
      source_file
      |> SourceFile.lines()
      |> length()

    if line_count > max_lines do
      [issue_for(issue_meta, line_count, max_lines)]
    else
      []
    end
  end

  defp issue_for(issue_meta, line_count, max_lines) do
    format_issue(
      issue_meta,
      message:
        "File has #{line_count} lines, exceeding the maximum of #{max_lines}. " <>
          "Consider splitting this module (e.g. into Ragex.Plugin implementations).",
      line_no: 1
    )
  end
end
