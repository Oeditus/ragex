defmodule Mix.Tasks.Ragex.Embeddings.Migrate do
  @moduledoc """
  Migrates embeddings when changing embedding models.

  This task helps handle model changes by detecting dimension mismatches
  and regenerating embeddings with the new model.

  ## Usage

      # Check current model and embeddings
      mix ragex.embeddings.migrate --check
      
      # Migrate to a new model (regenerate all embeddings)
      mix ragex.embeddings.migrate --model all_mpnet_base_v2
      
      # Force migration (skip compatibility check)
      mix ragex.embeddings.migrate --model codebert_base --force
      
      # Clear all embeddings
      mix ragex.embeddings.migrate --clear

  ## Options

    * `--check` - Check current model and embedding status
    * `--model MODEL_ID` - Migrate to specified model
    * `--force` - Force migration even if dimensions are compatible
    * `--clear` - Clear all embeddings (use before switching models)

  ## Model IDs

    * `all_minilm_l6_v2` (default) - 384 dimensions
    * `all_mpnet_base_v2` - 768 dimensions
    * `codebert_base` - 768 dimensions
    * `paraphrase_multilingual` - 384 dimensions
  """

  @shortdoc "Migrates embeddings when changing embedding models"

  use Mix.Task

  alias Ragex.Embeddings.Registry
  alias Ragex.Graph.Store
  alias Ragex.CLI.{Colors, Output, Prompt}

  @impl Mix.Task
  def run(args) do
    # Start the application to ensure ETS tables exist
    {:ok, _} = Application.ensure_all_started(:ragex)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          check: :boolean,
          model: :string,
          force: :boolean,
          clear: :boolean
        ],
        aliases: [
          c: :check,
          m: :model,
          f: :force
        ]
      )

    cond do
      opts[:check] ->
        check_status()

      opts[:clear] ->
        clear_embeddings()

      opts[:model] ->
        migrate_to_model(opts[:model], opts[:force] || false)

      true ->
        IO.puts(
          Colors.error("Usage: mix ragex.embeddings.migrate [--check|--model MODEL_ID|--clear]")
        )

        IO.puts(Colors.muted("Run 'mix help ragex.embeddings.migrate' for more information"))
    end
  end

  defp check_status do
    Output.section("Embedding Model Status")

    # Get current configured model
    current_model_id = Application.get_env(:ragex, :embedding_model, Registry.default())
    display_configured_model(current_model_id)

    # Check existing embeddings
    embeddings = Store.list_embeddings()
    check_embeddings_status(embeddings, current_model_id)

    # Show available models
    display_available_models(current_model_id)
    IO.puts("")
  end

  defp display_configured_model(current_model_id) do
    case Registry.get(current_model_id) do
      {:ok, model_info} ->
        IO.puts(Colors.bold("Configured Model:"))

        Output.key_value(
          [
            {"Name", model_info.name},
            {"ID", Colors.highlight(to_string(model_info.id))},
            {"Dimensions", model_info.dimensions},
            {"Type", model_info.type},
            {"Repository", model_info.repo}
          ],
          indent: 2
        )

        IO.puts("")

      {:error, :not_found} ->
        IO.puts(Colors.error("✗ Invalid model configured: #{inspect(current_model_id)}"))
        IO.puts("")
    end
  end

  defp check_embeddings_status([], _current_model_id) do
    IO.puts(Colors.muted("✓ No embeddings stored yet"))
    IO.puts("")
  end

  defp check_embeddings_status(embeddings, current_model_id) do
    {sample_type, sample_id, sample_embedding, _text} = hd(embeddings)
    embedding_dims = length(sample_embedding)

    IO.puts(Colors.bold("Stored Embeddings:"))

    Output.key_value(
      [
        {"Count", Colors.highlight(to_string(length(embeddings)))},
        {"Dimensions", embedding_dims},
        {"Sample", "#{sample_type} #{inspect(sample_id)}"}
      ],
      indent: 2
    )

    IO.puts("")

    check_compatibility(current_model_id, embedding_dims)
  end

  defp check_compatibility(current_model_id, embedding_dims) do
    case Registry.get(current_model_id) do
      {:ok, model_info} ->
        if model_info.dimensions == embedding_dims do
          IO.puts(
            Colors.success(
              "✓ Model and embeddings are compatible (#{model_info.dimensions} dimensions)"
            )
          )

          IO.puts("")
        else
          display_incompatibility_error(model_info.dimensions, embedding_dims)
        end

      _ ->
        :ok
    end
  end

  defp display_incompatibility_error(model_dims, embedding_dims) do
    IO.puts(Colors.error("✗ INCOMPATIBILITY DETECTED!"))

    Output.key_value(
      [
        {"Configured model", "#{model_dims} dimensions"},
        {"Stored embeddings", "#{embedding_dims} dimensions"}
      ],
      indent: 2
    )

    IO.puts("\n" <> Colors.warning("Action required:"))

    Output.list(
      [
        "Change config to use a compatible model",
        "OR run: #{Colors.highlight("mix ragex.embeddings.migrate --clear")}",
        "Then re-analyze your codebase"
      ], indent: 4, bullet: "→")

    IO.puts("")
  end

  defp display_available_models(current_model_id) do
    IO.puts(Colors.bold("Available Models:"))

    for model <- Registry.all() do
      marker = if model.id == current_model_id, do: Colors.highlight(" (current)"), else: ""
      IO.puts("  • #{Colors.info(to_string(model.id))}#{marker}")
      IO.puts(Colors.muted("    #{model.name} - #{model.dimensions} dims"))
    end
  end

  defp migrate_to_model(model_id_str, force) do
    model_id = String.to_atom(model_id_str)

    case Registry.get(model_id) do
      {:error, :not_found} ->
        display_unknown_model_error(model_id_str)

      {:ok, target_model} ->
        perform_migration(model_id, target_model, force)
    end
  end

  defp display_unknown_model_error(model_id_str) do
    IO.puts(Colors.error("✗ Unknown model: #{model_id_str}"))
    IO.puts("\n" <> Colors.bold("Available models:"))

    for model <- Registry.all() do
      IO.puts("  • #{Colors.info(to_string(model.id))}")
    end

    IO.puts("")
  end

  defp perform_migration(model_id, target_model, force) do
    Output.section("Model Migration")
    IO.puts(Colors.info("Target model: #{target_model.name}"))
    IO.puts("")

    embeddings = Store.list_embeddings()
    current_model_id = Application.get_env(:ragex, :embedding_model, Registry.default())

    if embeddings != [] and not force do
      handle_existing_embeddings(current_model_id, model_id, target_model)
    else
      display_clean_migration_steps(model_id)
    end
  end

  defp handle_existing_embeddings(current_model_id, target_model_id, target_model) do
    {:ok, current_model} = Registry.get(current_model_id)

    if Registry.compatible?(current_model_id, target_model_id) do
      display_compatible_migration(target_model_id)
    else
      display_incompatible_migration(current_model, target_model, target_model_id)
    end
  end

  defp display_compatible_migration(model_id) do
    IO.puts(Colors.success("✓ Models are compatible (same dimensions)"))
    IO.puts(Colors.muted("No migration needed. Update config.exs to:"))
    IO.puts(Colors.highlight("  config :ragex, :embedding_model, :#{model_id}"))
    IO.puts(Colors.muted("\nOr set environment variable:"))
    IO.puts(Colors.highlight("  export RAGEX_EMBEDDING_MODEL=#{model_id}"))
    IO.puts("")
  end

  defp display_incompatible_migration(current_model, target_model, model_id) do
    IO.puts(Colors.error("✗ Dimension mismatch detected!"))

    Output.key_value(
      [
        {"Current", "#{current_model.dimensions} dimensions"},
        {"Target", "#{target_model.dimensions} dimensions"}
      ],
      indent: 2
    )

    IO.puts("\n" <> Colors.warning("You must regenerate embeddings:"))

    Output.list(
      [
        "Clear existing: #{Colors.highlight("mix ragex.embeddings.migrate --clear")}",
        "Update config.exs: #{Colors.highlight("config :ragex, :embedding_model, :#{model_id}")}",
        "Re-analyze your codebase"
      ], indent: 4, bullet: "→")

    IO.puts("")
  end

  defp display_clean_migration_steps(model_id) do
    IO.puts(Colors.success("✓ No embeddings to migrate (or --force specified)"))
    IO.puts("\n" <> Colors.bold("Next steps:"))

    Output.list(
      [
        "Update config.exs: #{Colors.highlight("config :ragex, :embedding_model, :#{model_id}")}",
        "Restart server",
        "Analyze your codebase"
      ], indent: 2, bullet: "→")

    IO.puts("")
  end

  defp clear_embeddings do
    Output.section("Clear Embeddings")

    embeddings = Store.list_embeddings()
    count = length(embeddings)

    if count == 0 do
      IO.puts(Colors.success("✓ No embeddings to clear"))
      IO.puts("")
    else
      IO.puts(Colors.info("Found #{count} embeddings"))
      IO.puts("")

      if Prompt.confirm("Clear all embeddings?", default: :no) do
        IO.puts("\n" <> Colors.bold("To clear embeddings:"))

        Output.list(
          [
            "Stop the server",
            "Embeddings are stored in memory (ETS)",
            "They will be cleared on next restart"
          ], indent: 2, bullet: "→")

        IO.puts(
          "\n" <> Colors.muted("Or restart with clean state: kill the server process and restart")
        )

        IO.puts("")
      else
        IO.puts(Colors.muted("Cancelled."))
        IO.puts("")
      end
    end
  end
end
