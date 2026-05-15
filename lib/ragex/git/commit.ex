defmodule Ragex.Git.Commit do
  @moduledoc """
  A parsed git commit with metadata.

  ## Fields

  - `:sha` -- full commit hash
  - `:short_sha` -- abbreviated hash (first 8 chars)
  - `:author` -- author name
  - `:email` -- author email
  - `:date` -- `DateTime` of the commit
  - `:message` -- full commit message
  - `:summary` -- first line of the commit message
  - `:files_changed` -- list of `{path, status}` tuples (populated by `log` with `--name-status`)
  """

  @type t :: %__MODULE__{
          sha: String.t(),
          short_sha: String.t(),
          author: String.t(),
          email: String.t(),
          date: DateTime.t() | nil,
          message: String.t(),
          summary: String.t(),
          files_changed: [{String.t(), atom()}]
        }

  @enforce_keys [:sha, :author, :summary]
  defstruct [
    :sha,
    :short_sha,
    :author,
    :email,
    :date,
    :message,
    :summary,
    files_changed: []
  ]
end
