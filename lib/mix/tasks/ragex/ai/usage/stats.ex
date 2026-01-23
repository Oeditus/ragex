defmodule Mix.Tasks.Ragex.Ai.Usage.Stats do
  @moduledoc """
  Display AI provider usage statistics and costs.

  ## Usage

      # Show all providers
      mix ragex.ai.usage.stats
      
      # Show specific provider
      mix ragex.ai.usage.stats --provider openai
      mix ragex.ai.usage.stats --provider anthropic

  Shows request counts, token usage, and estimated costs per provider.
  """

  use Mix.Task
  require Logger
  alias Ragex.AI.Usage
  alias Ragex.CLI.{Colors, Output}

  @shortdoc "Display AI usage statistics"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} = OptionParser.parse!(args, strict: [provider: :string])

    case Keyword.get(opts, :provider) do
      nil ->
        # Show all providers
        stats = Usage.get_stats(:all)

        Output.section("AI Usage Statistics (All Providers)")

        total_requests = 0
        total_tokens = 0
        total_cost = 0.0

        {total_requests, total_tokens, total_cost} =
          Enum.reduce(stats, {total_requests, total_tokens, total_cost}, fn {provider,
                                                                             provider_stats},
                                                                            {req, tok, cost} ->
            IO.puts("\n" <> Colors.bold("#{provider}"))
            print_provider_stats(provider_stats)

            {
              req + provider_stats.total_requests,
              tok + provider_stats.total_tokens,
              cost + provider_stats.estimated_cost
            }
          end)

        IO.puts("\n" <> Colors.bold("Total Across All Providers"))

        Output.key_value(
          [
            {"Total requests", Colors.highlight(to_string(total_requests))},
            {"Total tokens", format_number(total_tokens)},
            {"Estimated cost", "$#{Float.round(total_cost, 4)}"}
          ],
          indent: 2
        )

        IO.puts("")

      provider_str ->
        provider = String.to_atom(provider_str)
        stats = Usage.get_stats(provider)

        if map_size(stats) == 0 do
          IO.puts(Colors.muted("No usage data for provider: #{provider}"))
          IO.puts("")
        else
          Output.section("AI Usage Statistics (#{provider})")
          print_provider_stats(stats)
          IO.puts("")
        end
    end
  end

  defp print_provider_stats(stats) do
    Output.key_value(
      [
        {"Requests", Colors.highlight(to_string(stats.total_requests))},
        {"Prompt tokens", format_number(stats.total_prompt_tokens)},
        {"Completion tokens", format_number(stats.total_completion_tokens)},
        {"Total tokens", format_number(stats.total_tokens)},
        {"Estimated cost", "$#{Float.round(stats.estimated_cost, 4)}"}
      ],
      indent: 2
    )

    if map_size(stats.by_model) > 0 do
      IO.puts("\n" <> Colors.muted("By Model:"))

      Enum.each(stats.by_model, fn {model, model_stats} ->
        IO.puts("  " <> Colors.info(to_string(model)) <> ":")

        Output.key_value(
          [
            {"Requests", model_stats.requests},
            {"Tokens", format_number(model_stats.total_tokens)},
            {"Cost", "$#{Float.round(model_stats.cost, 4)}"}
          ],
          indent: 4
        )
      end)
    end
  end

  defp format_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 2)}M"
  end

  defp format_number(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 2)}K"
  end

  defp format_number(num), do: to_string(num)
end
