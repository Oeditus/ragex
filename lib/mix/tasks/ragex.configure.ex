defmodule Mix.Tasks.Ragex.Configure do
  @moduledoc """
  Interactive configuration wizard for Ragex setup.

  ## Usage

      # Launch interactive wizard
      mix ragex.configure
      
      # Show current configuration
      mix ragex.configure --show

  Creates a `.ragex.exs` configuration file in your project root with:

  - Project type detection (Elixir, Erlang, Python, JS/TS, polyglot)
  - Embedding model selection with comparison table
  - AI provider configuration (OpenAI, Anthropic, DeepSeek, Ollama)
  - Analysis options (exclusions, cache settings)
  - Custom analysis rules

  The wizard detects your project structure and suggests optimal defaults.
  """

  @shortdoc "Interactive configuration wizard"

  use Mix.Task

  alias Ragex.CLI.{Colors, Output, Prompt}
  alias Ragex.Embeddings.Registry

  @config_file ".ragex.exs"

  @ai_providers [
    {:openai, "OpenAI (GPT-4, GPT-3.5)", "OPENAI_API_KEY"},
    {:anthropic, "Anthropic (Claude)", "ANTHROPIC_API_KEY"},
    {:deepseek, "DeepSeek (DeepSeek-Coder)", "DEEPSEEK_API_KEY"},
    {:deepseek_r1, "DeepSeek R1 (Reasoning)", "DEEPSEEK_R1_API_KEY"},
    {:ollama, "Ollama (Local Models)", nil}
  ]

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ragex)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [show: :boolean, help: :boolean],
        aliases: [s: :show, h: :help]
      )

    cond do
      opts[:help] ->
        show_help()

      opts[:show] ->
        show_current_config()

      true ->
        run_wizard()
    end
  end

  defp run_wizard do
    Output.section("Ragex Configuration Wizard")

    IO.puts(Colors.muted("This wizard will help you set up Ragex for your project."))
    IO.puts(Colors.muted("You can change these settings later by editing #{@config_file}"))
    IO.puts("")

    # Check if config already exists
    if File.exists?(@config_file) do
      IO.puts(Colors.warning("⚠ Configuration file already exists: #{@config_file}"))

      unless Prompt.confirm("Overwrite existing configuration?", default: :no) do
        IO.puts(Colors.muted("Configuration cancelled."))
        IO.puts("")
        System.halt(0)
      end

      IO.puts("")
    end

    # Gather configuration
    config = %{
      project_type: detect_and_confirm_project_type(),
      embedding_model: select_embedding_model(),
      ai_providers: configure_ai_providers(),
      analysis_options: configure_analysis_options(),
      cache_settings: configure_cache_settings()
    }

    # Preview configuration
    unless preview_config(config) do
      IO.puts(Colors.muted("Configuration cancelled."))
      IO.puts("")
      System.halt(0)
    end

    # Write configuration file
    write_config_file(config)

    Output.section("Setup Complete")

    IO.puts(Colors.success("✓ Configuration saved to #{@config_file}"))
    IO.puts("")
    IO.puts(Colors.bold("Next steps:"))

    Output.list(
      [
        "Analyze your codebase: #{Colors.highlight("mix ragex.cache.refresh --path .")}",
        "Start the MCP server: #{Colors.highlight("mix ragex.server")}",
        "Or run interactive refactoring: #{Colors.highlight("mix ragex.refactor")}"
      ], indent: 2, bullet: "→")

    IO.puts("")
  end

  defp detect_and_confirm_project_type do
    Output.section("Project Type Detection")

    detected = detect_project_languages()

    IO.puts(Colors.info("Detected languages:"))

    if detected == [] do
      IO.puts(Colors.muted("  (none detected)"))
    else
      Enum.each(detected, fn lang ->
        IO.puts("  • #{Colors.highlight(lang)}")
      end)
    end

    IO.puts("")

    # Let user select primary language
    language_options = [
      "elixir - Elixir projects",
      "erlang - Erlang/OTP projects",
      "python - Python projects",
      "javascript - JavaScript/TypeScript projects",
      "polyglot - Multiple languages"
    ]

    IO.puts("Select primary project type:")
    index = Prompt.select(language_options, default: default_language_index(detected))

    primary_type =
      case index do
        0 -> :elixir
        1 -> :erlang
        2 -> :python
        3 -> :javascript
        4 -> :polyglot
      end

    IO.puts("")
    IO.puts(Colors.success("Selected: #{primary_type}"))
    IO.puts("")

    primary_type
  end

  defp detect_project_languages do
    languages = []

    # Check for Elixir
    languages =
      if File.exists?("mix.exs") or File.dir?("lib") do
        ["Elixir" | languages]
      else
        languages
      end

    # Check for Erlang
    languages =
      if File.exists?("rebar.config") or File.dir?("src") do
        ["Erlang" | languages]
      else
        languages
      end

    # Check for Python
    languages =
      if File.exists?("setup.py") or File.exists?("pyproject.toml") or
           File.exists?("requirements.txt") do
        ["Python" | languages]
      else
        languages
      end

    # Check for JavaScript/TypeScript
    languages =
      if File.exists?("package.json") or File.exists?("tsconfig.json") do
        ["JavaScript/TypeScript" | languages]
      else
        languages
      end

    Enum.reverse(languages)
  end

  defp default_language_index(detected) do
    cond do
      "Elixir" in detected -> 0
      "Erlang" in detected -> 1
      "Python" in detected -> 2
      "JavaScript/TypeScript" in detected -> 3
      length(detected) > 1 -> 4
      true -> 0
    end
  end

  defp select_embedding_model do
    Output.section("Embedding Model Selection")

    IO.puts(Colors.bold("Available models:"))
    IO.puts("")

    models = Registry.all()

    # Display model comparison
    for {index, model} <- Enum.with_index(models) do
      marker = if model.id == Registry.default(), do: " (default)", else: ""
      IO.puts("#{index + 1}. #{Colors.info(to_string(model.id))}#{marker}")
      IO.puts(Colors.muted("   #{model.name}"))

      Output.key_value(
        [
          {"Dimensions", model.dimensions},
          {"Type", model.type},
          {"Best for", model_use_case(model.id)}
        ],
        indent: 3
      )

      IO.puts("")
    end

    IO.puts(Colors.muted("Recommendation: all_minilm_l6_v2 (default) for balanced speed/quality"))
    IO.puts("")

    model_names = Enum.map(models, &to_string(&1.id))
    index = Prompt.select(model_names, default: 0)
    selected_model = Enum.at(models, index)

    IO.puts("")
    IO.puts(Colors.success("Selected: #{selected_model.id}"))
    IO.puts("")

    selected_model.id
  end

  defp model_use_case(:all_minilm_l6_v2), do: "General purpose, fast"
  defp model_use_case(:all_mpnet_base_v2), do: "High quality, slower"
  defp model_use_case(:codebert_base), do: "Code-specific, technical"
  defp model_use_case(:paraphrase_multilingual), do: "Multi-language support"
  defp model_use_case(_), do: "General purpose"

  defp configure_ai_providers do
    Output.section("AI Provider Configuration")

    IO.puts(Colors.muted("Configure AI providers for enhanced analysis features."))
    IO.puts(Colors.muted("Leave API keys empty to skip provider setup."))
    IO.puts("")

    providers =
      for {provider_id, provider_name, env_var} <- @ai_providers do
        IO.puts(Colors.bold(provider_name))

        if env_var do
          IO.puts(Colors.muted("Environment variable: #{env_var}"))

          # Check if already set
          current_key = System.get_env(env_var)

          if current_key do
            IO.puts(Colors.success("✓ API key already set in environment"))
            use_existing = Prompt.confirm("Use existing key?", default: :yes)

            if use_existing do
              IO.puts("")
              {provider_id, %{enabled: true, use_env: true}}
            else
              api_key = Prompt.input("API key (or empty to skip)", default: "", masked: true)
              IO.puts("")

              if api_key == "" do
                {provider_id, %{enabled: false}}
              else
                {provider_id, %{enabled: true, api_key: api_key}}
              end
            end
          else
            api_key = Prompt.input("API key (or empty to skip)", default: "", masked: true)
            IO.puts("")

            if api_key == "" do
              {provider_id, %{enabled: false}}
            else
              {provider_id, %{enabled: true, api_key: api_key}}
            end
          end
        else
          # Ollama - no API key needed
          enabled = Prompt.confirm("Enable Ollama (local models)?", default: :no)
          IO.puts("")

          if enabled do
            base_url = Prompt.input("Ollama base URL", default: "http://localhost:11434")
            IO.puts("")
            {provider_id, %{enabled: true, base_url: base_url}}
          else
            {provider_id, %{enabled: false}}
          end
        end
      end

    Map.new(providers)
  end

  defp configure_analysis_options do
    Output.section("Analysis Options")

    IO.puts(Colors.muted("Configure which files and directories to analyze."))
    IO.puts("")

    # Exclusions
    IO.puts(Colors.bold("File/directory exclusions:"))
    default_exclusions = suggest_exclusions()

    IO.puts(Colors.muted("Default exclusions: #{Enum.join(default_exclusions, ", ")}"))

    use_defaults = Prompt.confirm("Use default exclusions?", default: :yes)
    IO.puts("")

    exclusions =
      if use_defaults do
        default_exclusions
      else
        IO.puts("Enter patterns to exclude (comma-separated):")
        input = Prompt.input("Exclusions", default: Enum.join(default_exclusions, ","))
        String.split(input, ",") |> Enum.map(&String.trim/1)
      end

    # Max file size
    IO.puts(Colors.bold("Maximum file size:"))
    max_size = Prompt.number("Max file size (KB)", default: 1024, min: 1)
    IO.puts("")

    # Auto-analyze on save
    auto_analyze = Prompt.confirm("Enable auto-analysis on file changes?", default: :no)
    IO.puts("")

    %{
      exclusions: exclusions,
      max_file_size_kb: max_size,
      auto_analyze: auto_analyze
    }
  end

  defp suggest_exclusions do
    base_exclusions = ["_build", "deps", ".git", "node_modules", ".elixir_ls"]

    # Add language-specific exclusions
    extra =
      cond do
        File.exists?("mix.exs") -> ["cover"]
        File.exists?("package.json") -> ["dist", "build", ".next"]
        File.exists?("setup.py") -> ["__pycache__", "venv", ".pytest_cache"]
        true -> []
      end

    base_exclusions ++ extra
  end

  defp configure_cache_settings do
    Output.section("Cache Settings")

    IO.puts(Colors.muted("Configure caching behavior for embeddings and analysis."))
    IO.puts("")

    # Cache directory
    default_cache_dir = "~/.ragex/cache"
    IO.puts("Cache directory: #{default_cache_dir}")

    use_default = Prompt.confirm("Use default cache directory?", default: :yes)
    IO.puts("")

    cache_dir =
      if use_default do
        default_cache_dir
      else
        Prompt.input("Cache directory", default: default_cache_dir)
      end

    # TTL
    IO.puts(Colors.bold("Cache Time-To-Live (TTL):"))
    ttl_hours = Prompt.number("Hours until cache expires", default: 24, min: 1, max: 720)
    IO.puts("")

    # Auto-refresh
    auto_refresh = Prompt.confirm("Auto-refresh stale cache on startup?", default: :yes)
    IO.puts("")

    %{
      cache_dir: cache_dir,
      ttl_hours: ttl_hours,
      auto_refresh: auto_refresh
    }
  end

  defp preview_config(config) do
    Output.section("Configuration Preview")

    IO.puts(Colors.bold("Project Type:"))
    IO.puts("  #{config.project_type}")
    IO.puts("")

    IO.puts(Colors.bold("Embedding Model:"))
    IO.puts("  #{config.embedding_model}")
    IO.puts("")

    IO.puts(Colors.bold("AI Providers:"))

    enabled_providers =
      config.ai_providers
      |> Enum.filter(fn {_id, settings} -> settings.enabled end)
      |> Enum.map(fn {id, _settings} -> id end)

    if enabled_providers == [] do
      IO.puts(Colors.muted("  (none configured)"))
    else
      Enum.each(enabled_providers, fn provider ->
        IO.puts("  • #{Colors.success(to_string(provider))}")
      end)
    end

    IO.puts("")

    IO.puts(Colors.bold("Analysis Options:"))

    Output.key_value(
      [
        {"Exclusions", Enum.join(config.analysis_options.exclusions, ", ")},
        {"Max file size", "#{config.analysis_options.max_file_size_kb} KB"},
        {"Auto-analyze", if(config.analysis_options.auto_analyze, do: "yes", else: "no")}
      ],
      indent: 2
    )

    IO.puts("")

    IO.puts(Colors.bold("Cache Settings:"))

    Output.key_value(
      [
        {"Directory", config.cache_settings.cache_dir},
        {"TTL", "#{config.cache_settings.ttl_hours} hours"},
        {"Auto-refresh", if(config.cache_settings.auto_refresh, do: "yes", else: "no")}
      ],
      indent: 2
    )

    IO.puts("")

    Prompt.confirm("Save this configuration?", default: :yes)
  end

  defp write_config_file(config) do
    content = generate_config_content(config)

    File.write!(@config_file, content)
  end

  defp generate_config_content(config) do
    """
    # Ragex Configuration
    # Generated by mix ragex.configure on #{DateTime.utc_now() |> DateTime.to_string()}

    import Config

    # Project type: #{config.project_type}
    config :ragex, :project_type, :#{config.project_type}

    # Embedding model
    config :ragex, :embedding_model, :#{config.embedding_model}

    #{generate_ai_providers_config(config.ai_providers)}

    # Analysis options
    config :ragex, :analysis,
      exclusions: #{inspect(config.analysis_options.exclusions)},
      max_file_size_kb: #{config.analysis_options.max_file_size_kb},
      auto_analyze: #{config.analysis_options.auto_analyze}

    # Cache settings
    config :ragex, :cache,
      cache_dir: "#{config.cache_settings.cache_dir}",
      ttl_hours: #{config.cache_settings.ttl_hours},
      auto_refresh: #{config.cache_settings.auto_refresh}

    # MCP Server settings
    config :ragex, :mcp,
      stdio: true,
      log_level: :info

    # Additional custom configuration can be added below
    """
  end

  defp generate_ai_providers_config(providers) do
    enabled =
      providers
      |> Enum.filter(fn {_id, settings} -> settings.enabled end)

    if enabled == [] do
      "# AI providers (none configured)\n# config :ragex, :ai_providers, []"
    else
      configs =
        Enum.map(enabled, fn {provider_id, settings} ->
          if Map.has_key?(settings, :use_env) do
            "  #{provider_id}: %{api_key: {:system, \"#{get_env_var_name(provider_id)}\"}}"
          else
            case provider_id do
              :ollama ->
                "  #{provider_id}: %{base_url: \"#{settings.base_url}\"}"

              _ ->
                "  #{provider_id}: %{api_key: \"#{settings.api_key}\"}"
            end
          end
        end)

      """
      # AI providers
      config :ragex, :ai_providers, [
      #{Enum.join(configs, ",\n")}
      ]
      """
    end
  end

  defp get_env_var_name(provider_id) do
    case provider_id do
      :openai -> "OPENAI_API_KEY"
      :anthropic -> "ANTHROPIC_API_KEY"
      :deepseek -> "DEEPSEEK_API_KEY"
      :deepseek_r1 -> "DEEPSEEK_R1_API_KEY"
      _ -> "#{String.upcase(to_string(provider_id))}_API_KEY"
    end
  end

  defp show_current_config do
    Output.section("Current Configuration")

    if File.exists?(@config_file) do
      IO.puts(Colors.success("✓ Configuration file exists: #{@config_file}"))
      IO.puts("")

      # Read and display key settings
      display_config_summary()
    else
      IO.puts(Colors.muted("No configuration file found: #{@config_file}"))
      IO.puts("")
      IO.puts("Run #{Colors.highlight("mix ragex.configure")} to create one.")
      IO.puts("")
    end
  end

  defp display_config_summary do
    # Display key configuration values from application env
    IO.puts(Colors.bold("Active Configuration:"))
    IO.puts("")

    Output.key_value(
      [
        {"Project type", Application.get_env(:ragex, :project_type, :elixir)},
        {"Embedding model", Application.get_env(:ragex, :embedding_model, Registry.default())},
        {"Cache enabled", Application.get_env(:ragex, :cache_enabled, true)}
      ],
      indent: 2
    )

    IO.puts("")

    # AI providers
    providers = Application.get_env(:ragex, :ai_providers, [])

    IO.puts(Colors.bold("Configured AI Providers:"))

    if providers == [] do
      IO.puts(Colors.muted("  (none)"))
    else
      Enum.each(providers, fn {provider, _settings} ->
        IO.puts("  • #{provider}")
      end)
    end

    IO.puts("")
  end

  defp show_help do
    IO.puts("""
    #{Colors.bold("Ragex Configuration Wizard")}

    #{Colors.info("Interactive configuration:")}
      mix ragex.configure

    #{Colors.info("Show current configuration:")}
      mix ragex.configure --show

    #{Colors.info("What gets configured:")}
      • Project type detection (Elixir, Erlang, Python, JS/TS, polyglot)
      • Embedding model selection with comparison
      • AI provider setup (OpenAI, Anthropic, DeepSeek, Ollama)
      • Analysis options (exclusions, file size limits)
      • Cache settings (directory, TTL, auto-refresh)

    The wizard creates a #{Colors.highlight(".ragex.exs")} file in your project root.

    #{Colors.muted("You can edit this file manually or re-run the wizard to update.")}
    """)
  end
end
