defmodule Mix.Tasks.Ragex.Setup do
  @shortdoc "Set up Ragex MCP integration for your AI editor"
  @moduledoc """
  Interactive setup for Ragex MCP integration with AI editors.

  Detects which editors are in use, generates the correct MCP config,
  and optionally runs initial analysis and model download.

  ## Usage

      mix ragex.setup                # Interactive mode
      mix ragex.setup --editor claude  # Specific editor
      mix ragex.setup --all           # All detected editors
      mix ragex.setup --list          # List supported editors

  ## Options

  - `--editor NAME` -- generate config for a specific editor
    (claude, cursor, vscode, zed, gemini, neovim, opencode)
  - `--all` -- generate for all detected editors
  - `--list` -- list supported editors and exit
  - `--force` -- overwrite existing configs
  - `--skip-analyze` -- skip initial project analysis
  - `--skip-models` -- skip embedding model download
  """

  use Mix.Task

  alias Ragex.CLI.EditorConfig

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          editor: :string,
          all: :boolean,
          list: :boolean,
          force: :boolean,
          skip_analyze: :boolean,
          skip_models: :boolean
        ]
      )

    cond do
      opts[:list] ->
        list_editors()

      opts[:all] ->
        setup_all(opts)

      opts[:editor] ->
        setup_editor(String.to_atom(opts[:editor]), opts)

      true ->
        interactive_setup(opts)
    end
  end

  defp list_editors do
    Mix.shell().info("\nSupported editors:\n")

    EditorConfig.editor_choices()
    |> Enum.each(fn {name, key} ->
      Mix.shell().info("  #{key}\t-- #{name}")
    end)

    Mix.shell().info("")
  end

  defp setup_all(opts) do
    project_dir = File.cwd!()
    gen_opts = if opts[:force], do: [force: true], else: []

    Mix.shell().info("Setting up Ragex for all detected editors in #{project_dir}...")

    results = EditorConfig.generate_all(project_dir, gen_opts)

    Enum.each(results, fn {editor, result} ->
      case result do
        {:ok, path} -> Mix.shell().info("  [ok] #{editor}: #{path}")
        {:error, reason} -> Mix.shell().error("  [error] #{editor}: #{inspect(reason)}")
      end
    end)

    post_setup(project_dir, opts)
  end

  defp setup_editor(editor, opts) do
    project_dir = File.cwd!()
    gen_opts = if opts[:force], do: [force: true], else: []

    case EditorConfig.generate(editor, project_dir, gen_opts) do
      {:ok, path} ->
        Mix.shell().info("Created #{path}")
        post_setup(project_dir, opts)

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp interactive_setup(opts) do
    project_dir = File.cwd!()

    Mix.shell().info("\nRagex Editor Setup")
    Mix.shell().info("==================\n")

    # Detect existing editors
    detected = EditorConfig.detect_editors(project_dir)

    if detected != [] do
      Mix.shell().info("Detected editor configs:")

      Enum.each(detected, fn {key, info} ->
        Mix.shell().info("  - #{info.name} (#{info.config_path})")
      end)

      Mix.shell().info("")

      if Mix.shell().yes?("Generate Ragex MCP config for these editors?") do
        setup_all(opts)
      end
    else
      Mix.shell().info("No existing editor configs detected.")
      Mix.shell().info("Which editor do you want to set up?\n")

      choices = EditorConfig.editor_choices()

      Enum.with_index(choices, 1)
      |> Enum.each(fn {{name, _key}, idx} ->
        Mix.shell().info("  #{idx}. #{name}")
      end)

      Mix.shell().info("")
      input = Mix.shell().prompt("Enter number (1-#{length(choices)})") |> String.trim()

      case Integer.parse(input) do
        {n, ""} when n >= 1 and n <= length(choices) ->
          {_name, key} = Enum.at(choices, n - 1)
          setup_editor(key, opts)

        _ ->
          Mix.shell().info("Generating Claude Code config (default)...")
          setup_editor(:claude, opts)
      end
    end
  end

  defp post_setup(project_dir, opts) do
    Mix.shell().info("")

    # Optionally run initial analysis
    unless opts[:skip_analyze] do
      if Mix.shell().yes?("Run initial project analysis?") do
        Mix.shell().info("Analyzing #{project_dir}...")
        Mix.Task.run("ragex.cache.refresh", ["--path", project_dir])
      end
    end

    # Optionally download models
    unless opts[:skip_models] do
      if Mix.shell().yes?("Download embedding model? (recommended for semantic search)") do
        Mix.Task.run("ragex.models.download", [])
      end
    end

    Mix.shell().info("\nSetup complete. Restart your editor to activate Ragex MCP.")
  end
end
