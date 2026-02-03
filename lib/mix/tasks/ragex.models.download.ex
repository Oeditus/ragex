defmodule Mix.Tasks.Ragex.Models.Download do
  use Mix.Task

  @shortdoc "Pre-downloads Bumblebee embedding models for offline use"

  @moduledoc """
  Downloads and caches Bumblebee embedding models for offline use.

  This task downloads all configured embedding models from HuggingFace and
  stores them in the Bumblebee cache directory. This is useful for:
  
  - Building Docker images with pre-cached models
  - Offline/air-gapped environments
  - Faster startup times (no download delay)

  ## Usage

      # Download default model only
      mix ragex.models.download

      # Download all available models
      mix ragex.models.download --all

      # Download specific model(s)
      mix ragex.models.download --models all_minilm_l6_v2,codebert_base

      # Use custom cache directory
      mix ragex.models.download --cache-dir /path/to/cache

  ## Options

    * `--all` - Download all available models from the registry
    * `--models` - Comma-separated list of model IDs to download
    * `--cache-dir` - Custom cache directory (overrides BUMBLEBEE_CACHE_DIR)
    * `--quiet` - Suppress informational output

  ## Cache Location

  Models are cached in:
  - Custom: Directory specified by --cache-dir or BUMBLEBEE_CACHE_DIR env var
  - Default: Platform-specific cache directory (~/.cache/bumblebee on Linux)

  Use `Bumblebee.cache_dir()` to see the active cache location.
  """

  require Logger
  alias Ragex.Embeddings.Registry

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [
      all: :boolean,
      models: :string,
      cache_dir: :string,
      quiet: :boolean
    ])

    # Start the application dependencies
    Mix.Task.run("app.start")

    # Set custom cache dir if provided
    if cache_dir = opts[:cache_dir] do
      System.put_env("BUMBLEBEE_CACHE_DIR", cache_dir)
    end

    quiet = Keyword.get(opts, :quiet, false)
    
    unless quiet do
      IO.puts("\nBumblebee Model Downloader")
      IO.puts("=" |> String.duplicate(50))
      IO.puts("Cache directory: #{Bumblebee.cache_dir()}\n")
    end

    # Determine which models to download
    models_to_download = cond do
      opts[:all] ->
        Registry.all()
      
      opts[:models] ->
        opts[:models]
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.to_atom/1)
        |> Enum.map(&Registry.get!/1)
      
      true ->
        [Registry.get!(Registry.default())]
    end

    unless quiet do
      IO.puts("Models to download: #{length(models_to_download)}\n")
    end

    # Download each model
    results = Enum.map(models_to_download, fn model ->
      download_model(model, quiet)
    end)

    # Summary
    success_count = Enum.count(results, &(&1 == :ok))
    failure_count = length(results) - success_count

    unless quiet do
      IO.puts("\n" <> "=" |> String.duplicate(50))
      IO.puts("Summary:")
      IO.puts("  Success: #{success_count}")
      IO.puts("  Failed:  #{failure_count}")
      
      if failure_count > 0 do
        IO.puts("\nSome models failed to download. Check the errors above.")
      else
        IO.puts("\nAll models downloaded successfully!")
      end
    end

    if failure_count > 0 do
      exit({:shutdown, 1})
    end
  end

  defp download_model(model, quiet) do
    unless quiet do
      IO.puts("Downloading: #{model.name}")
      IO.puts("  Repository: #{model.repo}")
      IO.puts("  Dimensions: #{model.dimensions}")
    end

    try do
      # Load tokenizer (triggers download)
      unless quiet, do: IO.write("  [1/2] Downloading tokenizer... ")
      {:ok, _tokenizer} = Bumblebee.load_tokenizer({:hf, model.repo})
      unless quiet, do: IO.puts("✓")

      # Load model (triggers download)
      unless quiet, do: IO.write("  [2/2] Downloading model... ")
      {:ok, _model} = Bumblebee.load_model({:hf, model.repo})
      unless quiet, do: IO.puts("✓")

      unless quiet, do: IO.puts("  Status: Successfully downloaded\n")
      :ok
    rescue
      error ->
        unless quiet do
          IO.puts("✗")
          IO.puts("  Status: Failed - #{Exception.message(error)}\n")
        end
        Logger.error("Failed to download model #{model.name}: #{Exception.message(error)}")
        :error
    end
  end
end
