defmodule Ragex.Git.BlameEntry do
  @moduledoc """
  A single line (or contiguous range) from `git blame` output.

  ## Fields

  - `:sha` -- commit hash that last touched this line
  - `:author` -- author name
  - `:email` -- author email
  - `:date` -- `DateTime` of the commit
  - `:line` -- line number in the current file (1-indexed)
  - `:original_line` -- line number in the original commit
  - `:content` -- the line content (optional, may be nil for compact output)
  - `:summary` -- commit summary / first line of commit message
  """

  @type t :: %__MODULE__{
          sha: String.t(),
          author: String.t(),
          email: String.t(),
          date: DateTime.t() | nil,
          line: pos_integer(),
          original_line: pos_integer(),
          content: String.t() | nil,
          summary: String.t() | nil
        }

  @enforce_keys [:sha, :author, :email, :line]
  defstruct [
    :sha,
    :author,
    :email,
    :date,
    :line,
    :original_line,
    :content,
    :summary
  ]
end
