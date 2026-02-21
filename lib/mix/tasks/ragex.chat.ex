defmodule Mix.Tasks.Ragex.Chat do
  @moduledoc """
  Interactive chat session for codebase Q&A using RAG.

  ## Usage

      # Chat about the current directory
      mix ragex.chat

      # Chat about a specific project
      mix ragex.chat --path /path/to/project

      # Specify AI provider and model
      mix ragex.chat --provider deepseek_r1 --model deepseek-chat

      # Skip initial analysis (use existing graph data)
      mix ragex.chat --skip-analysis

      # Use specific retrieval strategy
      mix ragex.chat --strategy semantic_first

  ## Options

  - `--path`, `-p` - Project path (default: current directory)
  - `--provider` - AI provider: deepseek_r1, openai, anthropic, ollama
  - `--model`, `-m` - Model name override
  - `--strategy`, `-s` - Retrieval strategy: fusion, semantic_first, graph_first
  - `--skip-analysis` - Skip initial codebase analysis
  - `--help`, `-h` - Show this help

  ## Interactive Commands

  Once inside the chat, type `/help` to see available commands.
  """

  @shortdoc "Interactive chat for codebase Q&A"

  use Mix.Task

  alias Ragex.CLI.Chat

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          path: :string,
          provider: :string,
          model: :string,
          strategy: :string,
          skip_analysis: :boolean,
          help: :boolean
        ],
        aliases: [
          p: :path,
          m: :model,
          s: :strategy,
          h: :help
        ]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      {:ok, _} = Application.ensure_all_started(:ragex)

      chat_opts =
        []
        |> maybe_put(:path, opts[:path])
        |> maybe_put(:provider, parse_provider(opts[:provider]))
        |> maybe_put(:model, opts[:model])
        |> maybe_put(:strategy, parse_strategy(opts[:strategy]))
        |> maybe_put(:skip_analysis, opts[:skip_analysis])

      Chat.start(chat_opts)
    end
  end

  defp parse_provider(nil), do: nil
  defp parse_provider(name), do: String.to_existing_atom(name)

  defp parse_strategy(nil), do: nil
  defp parse_strategy(name), do: String.to_existing_atom(name)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
