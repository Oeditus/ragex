defmodule Ragex.MixProject do
  use Mix.Project

  @app :ragex
  @version "0.3.0"
  @source_url "https://github.com/Oeditus/ragex"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() not in [:dev, :test],
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_file: {:no_warn, ".dialyzer/dialyzer.plt"},
        plt_add_deps: :app_tree,
        plt_add_apps: [:mix],
        plt_core_path: ".dialyzer",
        list_unused_filters: true,
        ignore_warnings: ".dialyzer/ignore.exs"
      ],
      name: "Ragex",
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Ragex.Application, []},
      start_phases: [auto_analyze: []]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.github": :test
      ]
    ]
  end

  defp deps do
    [
      # Core dependencies
      {:jason, "~> 1.4"},
      {:file_system, "~> 1.0"},
      # TUI Framework
      {:owl, "~> 0.12"},
      # Embeddings and ML
      {:bumblebee, "~> 0.5"},
      {:nx, "~> 0.9"},
      {:exla, "~> 0.9"},
      # AI Provider
      {:req, "~> 0.5"},
      # Metastatic MetaAST
      case System.get_env("LOCAL_METASTATIC") do
        nil -> {:metastatic, "~> 0.5"}
        _ -> {:metastatic, path: "../metastatic"}
      end,
      # Development and documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      quality: ["format", "credo --strict"],
      "quality.ci": [
        "format --check-formatted",
        "credo --strict"
      ]
    ]
  end

  defp description do
    """
    Hybrid Retrieval-Augmented Generation (RAG) system for multi-language codebase analysis.
    MCP server combining static analysis, knowledge graphs, semantic search with local ML,
    and advanced graph algorithms for AI-powered code understanding.
    """
  end

  defp package do
    [
      name: @app,
      files: ~w(
        lib
        priv
        .formatter.exs
        mix.exs
        README.md
        CHANGELOG.md
        LICENSE
        stuff/img
        stuff/docs/ALGORITHMS.md
        stuff/docs/ANALYSIS.md
        stuff/docs/CONFIGURATION.md
        stuff/docs/PERSISTENCE.md
        stuff/docs/PROMPTS.md
        stuff/docs/RESOURCES.md
        stuff/docs/STREAMING.md
        stuff/docs/SUGGESTIONS.md
        stuff/docs/USAGE.md
        examples/product_cart/README.md
        examples/product_cart/DEMO.md
      ),
      licenses: ["GPL-3.0"],
      maintainers: ["Aleksei Matiushkin"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://hexdocs.pm/#{@app}"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "stuff/img/logo-48x48.png",
      assets: %{"stuff/img" => "assets"},
      extras: extras(),
      extra_section: "GUIDES",
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html", "epub"],
      groups_for_modules: groups_for_modules(),
      nest_modules_by_prefix: [
        Ragex.AI,
        Ragex.AI.Features,
        Ragex.Analysis,
        Ragex.Analysis.Suggestions,
        Ragex.Analyzers,
        Ragex.CLI,
        Ragex.Editor,
        Ragex.Embeddings,
        Ragex.Graph,
        Ragex.MCP,
        Ragex.MCP.Handlers,
        Ragex.RAG,
        Ragex.Retrieval
      ],
      authors: ["Aleksei Matiushkin"],
      canonical: "https://hexdocs.pm/#{@app}",
      skip_undefined_reference_warnings_on: [],
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  defp extras do
    [
      "README.md",
      "CHANGELOG.md": [title: "Changelog"],
      "stuff/docs/USAGE.md": [title: "Usage Guide"],
      "stuff/docs/CONFIGURATION.md": [title: "Configuration"],
      "stuff/docs/ALGORITHMS.md": [title: "Graph Algorithms"],
      "stuff/docs/ANALYSIS.md": [title: "Code Analysis"],
      "stuff/docs/SUGGESTIONS.md": [title: "Refactoring Suggestions"],
      "stuff/docs/PERSISTENCE.md": [title: "Persistence & Caching"],
      "stuff/docs/PROMPTS.md": [title: "MCP Prompts"],
      "stuff/docs/RESOURCES.md": [title: "MCP Resources"],
      "stuff/docs/STREAMING.md": [title: "Streaming Notifications"]
    ]
  end

  defp groups_for_modules do
    [
      "Core Components": [
        Ragex,
        Ragex.Application
      ],
      "MCP Server": [
        Ragex.MCP.Debug,
        Ragex.MCP.SingleRequest,
        Ragex.MCP.SocketServer,
        Ragex.MCP.Server,
        Ragex.MCP.Protocol,
        Ragex.MCP.Handlers.Initialization,
        Ragex.MCP.Handlers.Tools,
        Ragex.MCP.Handlers.Resources,
        Ragex.MCP.Handlers.Prompts
      ],
      "Code Analysis": [
        Ragex.Analyzers.Elixir,
        Ragex.Analyzers.Erlang,
        Ragex.Analyzers.Python,
        Ragex.Analyzers.JavaScript,
        Ragex.Analyzers.Detector
      ],
      "Knowledge Graph": [
        Ragex.Graph.Algorithms,
        Ragex.Graph.Store,
        Ragex.VectorStore
      ],
      "Embeddings & ML": [
        Ragex.Embeddings.Behaviour,
        Ragex.Embeddings.Bumblebee,
        Ragex.Embeddings.FileTracker,
        Ragex.Embeddings.Generator,
        Ragex.Embeddings.Helper,
        Ragex.Embeddings.ModelRegistry,
        Ragex.Embeddings.Persistence,
        Ragex.Embeddings.Registry,
        Ragex.Embeddings.TextGenerator
      ],
      RAG: [
        Ragex.RAG.ContextBuilder,
        Ragex.RAG.Pipeline,
        Ragex.RAG.PromptTemplate,
        Ragex.Retrieval.Hybrid,
        Ragex.Retrieval.Strategies,
        Ragex.Retrieval.CrossLanguage,
        Ragex.Retrieval.MetaASTRanker,
        Ragex.Retrieval.QueryExpansion
      ],
      "Code Editing": [
        Ragex.Editor.Core,
        Ragex.Editor.Types,
        Ragex.Editor.Backup,
        Ragex.Editor.Validator,
        Ragex.Editor.Transaction,
        Ragex.Editor.Refactor,
        Ragex.Editor.Advanced,
        Ragex.Editor.Conflict,
        Ragex.Editor.Diff,
        Ragex.Editor.Formatter,
        Ragex.Editor.Preview,
        Ragex.Editor.Refactor.AIPreview,
        Ragex.Editor.Refactor.Elixir,
        Ragex.Editor.Report,
        Ragex.Editor.Undo,
        Ragex.Editor.ValidationAI,
        Ragex.Editor.Validators.Elixir,
        Ragex.Editor.Validators.Erlang,
        Ragex.Editor.Validators.Javascript,
        Ragex.Editor.Validators.Python,
        Ragex.Editor.Visualize
      ],
      "Code Analysis & Quality": [
        Ragex.Analysis.Duplication,
        Ragex.Analysis.DeadCode,
        Ragex.Analysis.DependencyGraph,
        Ragex.Analysis.Impact,
        Ragex.Analysis.Suggestions,
        Ragex.Analysis.Suggestions.Patterns,
        Ragex.Analysis.Suggestions.Ranker,
        Ragex.Analysis.Suggestions.Actions,
        Ragex.Analysis.Suggestions.RAGAdvisor,
        Ragex.Analysis.BusinessLogic,
        Ragex.Analysis.DeadCode.AIRefiner,
        Ragex.Analysis.DependencyGraph.AIInsights,
        Ragex.Analysis.Duplication.AIAnalyzer,
        Ragex.Analysis.MetastaticBridge,
        Ragex.Analysis.Quality,
        Ragex.Analysis.QualityStore,
        Ragex.Analysis.Security,
        Ragex.Analysis.Smells,
        Ragex.Analyzers.Behaviour,
        Ragex.Analyzers.Directory,
        Ragex.Analyzers.Metastatic
      ],
      "AI Features": [
        Ragex.AI.Behaviour,
        Ragex.AI.Cache,
        Ragex.AI.Config,
        Ragex.AI.Provider.Anthropic,
        Ragex.AI.Provider.DeepSeekR1,
        Ragex.AI.Provider.Ollama,
        Ragex.AI.Provider.OpenAI,
        Ragex.AI.Provider.Registry,
        Ragex.AI.Registry,
        Ragex.AI.Usage,
        Ragex.AI.Features.Config,
        Ragex.AI.Features.Context,
        Ragex.AI.Features.Cache,
        Ragex.AI.Features.ValidationAI,
        Ragex.AI.Features.AIPreview,
        Ragex.AI.Features.AIRefiner,
        Ragex.AI.Features.AIAnalyzer,
        Ragex.AI.Features.AIInsights
      ],
      CLI: [
        Ragex.CLI.Colors,
        Ragex.CLI.Output,
        Ragex.CLI.Progress,
        Ragex.CLI.Prompt
      ],
      Utilities: [
        Ragex.Watcher
      ]
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script src="https://cdn.jsdelivr.net/npm/mermaid@10.9.0/dist/mermaid.min.js"></script>
    <script>
      document.addEventListener("DOMContentLoaded", function () {
        mermaid.initialize({
          startOnLoad: true,
          theme: "default",
          flowchart: {
            useMaxWidth: true,
            htmlLabels: true,
            curve: "basis"
          }
        });
        window.mermaid = mermaid;
      });
    </script>
    """
  end

  defp before_closing_body_tag(_), do: ""
end
