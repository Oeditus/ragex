defmodule Mix.Tasks.Ragex.Ci do
  @shortdoc "Run diff-based analysis for CI (ragex + metacredo)"

  @moduledoc """
  Runs both `mix ragex.analyze --diff` and `mix metacredo --diff` in
  sequence, exiting with a non-zero code if either finds issues.

  Designed as a single command for CI pipelines (GitHub Actions, etc.).

  ## Usage

      mix ragex.ci [options]

  ## Options

    * `--base REF` - Base git ref (default: origin/main)
    * `--head REF` - Head git ref (default: HEAD)
    * `--format FORMAT` - Output format: text, github (default: text)
    * `--config PATH` - Path to `.metacredo.exs` config file for metacredo
    * `--no-db` - Exclude DB-related checks and reports
    * `--no-user` - Exclude user-input-related checks and reports

  ## Examples

      # Run in a GitHub Actions PR workflow
      mix ragex.ci --base origin/$GITHUB_BASE_REF

      # With GitHub Actions inline annotations and suppressed DB/User reports
      mix ragex.ci --format github --no-db --no-user
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    args =
      Enum.map(args, fn
        "--no_db" -> "--no-db"
        "--no_user" -> "--no-user"
        other -> other
      end)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          base: :string,
          head: :string,
          format: :string,
          config: :string,
          no_db: :boolean,
          no_user: :boolean
        ]
      )

    base = opts[:base]
    head = opts[:head]
    format = opts[:format] || "text"
    no_db = opts[:no_db]
    no_user = opts[:no_user]

    # Build args for ragex.analyze --diff
    ragex_args =
      ["--diff", "--format", format] ++
        if(base, do: ["--base", base], else: []) ++
        if(head, do: ["--head", head], else: []) ++
        if(no_db, do: ["--no-db"], else: []) ++
        if(no_user, do: ["--no-user"], else: [])

    config = opts[:config]

    # Build args for metacredo --diff
    metacredo_args =
      ["--diff", "--strict", "--format", format] ++
        if(base, do: ["--base", base], else: []) ++
        if(head, do: ["--head", head], else: []) ++
        if(config, do: ["--config", config], else: []) ++
        if(no_db, do: ["--no-db"], else: []) ++
        if(no_user, do: ["--no-user"], else: [])

    # Run ragex.analyze first
    Mix.Task.run("ragex.analyze", ragex_args)

    # Run metacredo (reenable if already run in this session)
    Mix.Task.reenable("metacredo")
    Mix.Task.run("metacredo", metacredo_args)
  end
end
