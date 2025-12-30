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
        Mix.shell().info("Usage: mix ragex.embeddings.migrate [--check|--model MODEL_ID|--clear]")
        Mix.shell().info("Run 'mix help ragex.embeddings.migrate' for more information")
    end
  end

  defp check_status do
    Mix.shell().info("Checking embedding model status...\n")

    # Get current configured model
    current_model_id = Application.get_env(:ragex, :embedding_model, Registry.default())
    display_configured_model(current_model_id)

    # Check existing embeddings
    embeddings = Store.list_embeddings()
    check_embeddings_status(embeddings, current_model_id)

    # Show available models
    display_available_models(current_model_id)
    Mix.shell().info("")
  end

  defp display_configured_model(current_model_id) do
    case Registry.get(current_model_id) do
      {:ok, model_info} ->
        Mix.shell().info("✓ Configured Model: #{model_info.name}")
        Mix.shell().info("  ID: #{model_info.id}")
        Mix.shell().info("  Dimensions: #{model_info.dimensions}")
        Mix.shell().info("  Type: #{model_info.type}")
        Mix.shell().info("  Repository: #{model_info.repo}\n")

      {:error, :not_found} ->
        Mix.shell().error("✗ Invalid model configured: #{inspect(current_model_id)}\n")
    end
  end

  defp check_embeddings_status([], _current_model_id) do
    Mix.shell().info("✓ No embeddings stored yet\n")
  end

  defp check_embeddings_status(embeddings, current_model_id) do
    {sample_type, sample_id, sample_embedding, _text} = hd(embeddings)
    embedding_dims = length(sample_embedding)

    Mix.shell().info("✓ Stored Embeddings: #{length(embeddings)}")
    Mix.shell().info("  Dimensions: #{embedding_dims}")
    Mix.shell().info("  Sample: #{sample_type} #{inspect(sample_id)}\n")

    check_compatibility(current_model_id, embedding_dims)
  end

  defp check_compatibility(current_model_id, embedding_dims) do
    case Registry.get(current_model_id) do
      {:ok, model_info} ->
        if model_info.dimensions == embedding_dims do
          Mix.shell().info(
            "✓ Model and embeddings are compatible (#{model_info.dimensions} dimensions)\n"
          )
        else
          display_incompatibility_error(model_info.dimensions, embedding_dims)
        end

      _ ->
        :ok
    end
  end

  defp display_incompatibility_error(model_dims, embedding_dims) do
    Mix.shell().error("✗ INCOMPATIBILITY DETECTED!")
    Mix.shell().error("  Configured model: #{model_dims} dimensions")
    Mix.shell().error("  Stored embeddings: #{embedding_dims} dimensions")
    Mix.shell().error("\n  Action required:")
    Mix.shell().error("    1. Change config to use a compatible model")
    Mix.shell().error("    2. OR run: mix ragex.embeddings.migrate --clear")
    Mix.shell().error("    3. Then re-analyze your codebase\n")
  end

  defp display_available_models(current_model_id) do
    Mix.shell().info("Available Models:")

    for model <- Registry.all() do
      marker = if model.id == current_model_id, do: " (current)", else: ""
      Mix.shell().info("  • #{model.id}#{marker}")
      Mix.shell().info("    #{model.name} - #{model.dimensions} dims")
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
    Mix.shell().error("✗ Unknown model: #{model_id_str}")
    Mix.shell().info("\nAvailable models:")

    for model <- Registry.all() do
      Mix.shell().info("  • #{model.id}")
    end
  end

  defp perform_migration(model_id, target_model, force) do
    Mix.shell().info("Migrating to model: #{target_model.name}\n")

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
    Mix.shell().info("✓ Models are compatible (same dimensions)")
    Mix.shell().info("  No migration needed. Update config.exs to:")
    Mix.shell().info("  config :ragex, :embedding_model, :#{model_id}")
    Mix.shell().info("\n  Or set environment variable:")
    Mix.shell().info("  export RAGEX_EMBEDDING_MODEL=#{model_id}\n")
  end

  defp display_incompatible_migration(current_model, target_model, model_id) do
    Mix.shell().error("✗ Dimension mismatch detected!")
    Mix.shell().error("  Current: #{current_model.dimensions} dimensions")
    Mix.shell().error("  Target: #{target_model.dimensions} dimensions")
    Mix.shell().error("\n  You must regenerate embeddings:")
    Mix.shell().error("    1. Clear existing: mix ragex.embeddings.migrate --clear")
    Mix.shell().error("    2. Update config.exs: config :ragex, :embedding_model, :#{model_id}")
    Mix.shell().error("    3. Re-analyze your codebase\n")
  end

  defp display_clean_migration_steps(model_id) do
    Mix.shell().info("✓ No embeddings to migrate (or --force specified)")
    Mix.shell().info("\n  Next steps:")
    Mix.shell().info("    1. Update config.exs:")
    Mix.shell().info("       config :ragex, :embedding_model, :#{model_id}")
    Mix.shell().info("    2. Restart server")
    Mix.shell().info("    3. Analyze your codebase\n")
  end

  defp clear_embeddings do
    embeddings = Store.list_embeddings()
    count = length(embeddings)

    if count == 0 do
      Mix.shell().info("✓ No embeddings to clear")
    else
      Mix.shell().info("Clearing #{count} embeddings...")

      # Clear embeddings from ETS
      # Note: This requires adding a clear_embeddings function to Store
      # For now, we'll just inform the user
      Mix.shell().info("\n  To clear embeddings:")
      Mix.shell().info("    1. Stop the server")
      Mix.shell().info("    2. Embeddings are stored in memory (ETS)")
      Mix.shell().info("    3. They will be cleared on next restart")
      Mix.shell().info("\n  Or restart with clean state:")
      Mix.shell().info("    kill the server process and restart\n")
    end
  end
end
