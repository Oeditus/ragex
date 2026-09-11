defmodule Ragex.MixProject do
  use Mix.Project

  @app :ragex
  @version "0.33.0"
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
        # list_unused_filters: true,
        ignore_warnings: ".dialyzer/ignore.exs"
      ],
      name: "Ragex",
      source_url: @source_url,
      # `decimal` 2.4.1 (transitive, pulled in by the optional Nx/ML stack --
      # not a direct dependency of Ragex) has GHSA-rhv4-8758-jx7v (moderate,
      # unbounded-exponent DoS in Decimal.parse/new). The fix requires
      # decimal 3.0.0, a major bump that `mix deps.update decimal` cannot
      # apply on its own since no direct dependency here requests it -- it
      # needs nx/polaris/axon to move first. Ragex does not itself parse
      # untrusted decimal strings, so the practical exposure is low. Tracked
      # as a follow-up in the Ragex Codebase Health & Architecture
      # Improvement Plan rather than silently ignored forever.
      hex: [ignore_advisories: ["GHSA-rhv4-8758-jx7v"]]
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
      # dllb multi-model database client
      # if(File.dir?("../dllb_ex") or not is_nil(System.get_env("LOCAL_DLLB")),
      #   do: {:dllb, path: "../dllb_ex", override: true},
      #   else: {:dllb, "~> 0.9"}
      # ),
      {:dllb, "~> 0.9"},
      # TUI Framework
      {:owl, "~> 0.12"},
      # Embeddings and ML (optional -- native/NIF-backed, cannot load from
      # inside an escript archive; degrades gracefully when absent, see
      # Ragex.Embeddings.Bumblebee.available?/0)
      {:bumblebee, "~> 0.5", optional: true},
      {:nx, "~> 0.12", optional: true},
      {:exla, "~> 0.9", optional: true},
      # AI Provider
      {:req, "~> 0.5"},
      # Terminal Markdown rendering
      {:marcli, "~> 0.1"},
      {:makeup_elixir, "~> 1.0", optional: true},
      # Git integration (optional NIF for libgit2 -- falls back to CLI)
      {:egit, "~> 0.2", optional: true},
      # REST API bridge (Phase K)
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.16"},
      # MetaCredo analysis (transitively brings Metastatic for core types)
      case System.get_env("LOCAL_METACREDO") do
        nil -> {:metacredo, "~> 0.1"}
        _ -> {:metacredo, path: "../metacredo"}
      end,
      # Image processing library (optional -- native/NIF-backed via Vix/libvips,
      # degrades gracefully when absent, see Ragex.Image.available?/0)
      {:image, "~> 0.54", optional: true},
      # Development and documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      # Scans mix.lock for known security vulnerabilities (`mix deps.audit`)
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  # See the `hex: [ignore_advisories: ...]` comment above for why
  # GHSA-rhv4-8758-jx7v is excluded here too (mix_audit and `mix hex.audit`
  # draw from different advisory sources and are configured separately).
  @deps_audit_args "deps.audit --ignore-advisory-ids GHSA-rhv4-8758-jx7v"

  defp aliases do
    [
      quality: ["format", "credo --strict", @deps_audit_args],
      "quality.ci": [
        "format --check-formatted",
        "credo --strict",
        @deps_audit_args
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
        .metacredo.exs
        mix.exs
        README.md
        CHANGELOG.md
        LICENSE
        stuff/img
        stuff/img/*
        stuff/docs/ALGORITHMS.md
        stuff/docs/ANALYSIS.md
        stuff/docs/CONFIGURATION.md
        stuff/docs/PERSISTENCE.md
        stuff/docs/PROMPTS.md
        stuff/docs/RESOURCES.md
        stuff/docs/STREAMING.md
        stuff/docs/SUGGESTIONS.md
        stuff/docs/TOOLS.md
        stuff/docs/TROUBLESHOOTING.md
        stuff/docs/USAGE.md
        stuff/docs/ZED.md
        stuff/docs/CI.md
        stuff/docs/RAGEX-VS-CICADA.md
        stuff/docs/USE-LOCAL-RAGEX-AS-MCP.md
        docs/FEATURE_GUIDE.md
        docs/CHEATSHEET.cheatmd
        docs/WHY_RAGEX.md
        stuff/docs/CUSTOM_PLUGINS.md
        bin/ragex-mcp
        examples/product_cart/README.md
        examples/product_cart/DEMO.md
      ),
      licenses: ["GPL-3.0", "CC-BY-SA-4.0"],
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
      logo: "stuff/img/logo.png",
      assets: %{"stuff/img" => "assets"},
      extras: extras(),
      extra_section: "GUIDES",
      groups_for_extras: groups_for_extras(),
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html", "epub"],
      groups_for_modules: groups_for_modules(),
      nest_modules_by_prefix: [
        Ragex.AI,
        Ragex.AI.Features,
        Ragex.API,
        Ragex.Agent,
        Ragex.Analysis,
        Ragex.Analysis.Suggestions,
        Ragex.Analyzers,
        Ragex.CLI,
        Ragex.Dllb,
        Ragex.Editor,
        Ragex.Embeddings,
        Ragex.Git,
        Ragex.Graph,
        Ragex.MCP,
        Ragex.MCP.Handlers,
        Ragex.Plugins,
        Ragex.RAG,
        Ragex.Retrieval,
        Ragex.Store,
        Ragex.URLAnalyzer
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
      "docs/FEATURE_GUIDE.md": [title: "Feature Reference Manual"],
      "stuff/docs/CONFIGURATION.md": [title: "Configuration"],
      "stuff/docs/TROUBLESHOOTING.md": [title: "Troubleshooting"],
      "stuff/docs/CI.md": [title: "CI / Diff-Based Analysis"],
      "stuff/docs/CUSTOM_PLUGINS.md": [title: "Writing Custom Plugins"],
      "stuff/docs/RAGEX-VS-CICADA.md": [title: "Ragex vs Cicada"],
      "examples/product_cart/DEMO.md": [title: "Cart demo: README"],
      "docs/WHY_RAGEX.md": [title: "Why Ragex (Article)"],
      "stuff/docs/ZED.md": [title: "Zed Integration (Deprecated)"],
      "docs/CHEATSHEET.cheatmd": [title: "Cheatsheet"],
      "stuff/docs/USE-LOCAL-RAGEX-AS-MCP.md": [title: "Using Ragex as MCP Server"],
      "stuff/docs/PROMPTS.md": [title: "MCP Prompts"],
      "stuff/docs/RESOURCES.md": [title: "MCP Resources"],
      "stuff/docs/TOOLS.md": [title: "MCP Tools Reference"],
      "stuff/docs/ANALYSIS.md": [title: "Code Analysis"],
      "stuff/docs/ALGORITHMS.md": [title: "Graph Algorithms"],
      "stuff/docs/SUGGESTIONS.md": [title: "Refactoring Suggestions"],
      "stuff/docs/PERSISTENCE.md": [title: "Persistence & Caching"],
      "stuff/docs/STREAMING.md": [title: "Streaming Notifications"],
      "SERVER_GUIDE.md": [title: "Socket Server Guide"]
    ]
  end

  defp groups_for_extras do
    [
      Cheatsheets: [
        "docs/CHEATSHEET.cheatmd"
      ],
      "Features & Philosophy": [
        "docs/FEATURE_GUIDE.md",
        "docs/WHY_RAGEX.md",
        "stuff/docs/RAGEX-VS-CICADA.md",
        "stuff/docs/CUSTOM_PLUGINS.md"
      ],
      MCP: [
        "stuff/docs/USE-LOCAL-RAGEX-AS-MCP.md",
        "stuff/docs/PROMPTS.md",
        "stuff/docs/RESOURCES.md",
        "stuff/docs/TOOLS.md",
        "SERVER_GUIDE.md"
      ],
      "Under the Hood": [
        "stuff/docs/ANALYSIS.md",
        "stuff/docs/ALGORITHMS.md",
        "stuff/docs/SUGGESTIONS.md",
        "stuff/docs/PERSISTENCE.md",
        "stuff/docs/STREAMING.md"
      ]
    ]
  end

  defp groups_for_modules do
    [
      "Core Components": [
        Ragex,
        Ragex.LanguageSupport,
        Ragex.Plugin,
        Ragex.Plugin.EventBus,
        Ragex.Plugin.Registry
      ],
      Plugins: [
        Ragex.Plugins.CodeQuality,
        Ragex.Plugins.GitArchaeology,
        Ragex.Plugins.GraphAnalytics,
        Ragex.Plugins.SecurityAudit,
        Ragex.Plugins.URLAnalyzer
      ],
      "MCP Server": [
        Ragex.MCP.Client,
        Ragex.MCP.Debug,
        Ragex.MCP.Delegate,
        Ragex.MCP.Formattable,
        Ragex.MCP.Formatter,
        Ragex.MCP.SingleRequest,
        Ragex.MCP.SocketServer,
        Ragex.MCP.Server,
        Ragex.MCP.SocketPath,
        Ragex.MCP.Protocol,
        Ragex.MCP.Telemetry,
        Ragex.MCP.Handlers.GitTools,
        Ragex.MCP.Handlers.ImageTools,
        Ragex.MCP.Handlers.Initialization,
        Ragex.MCP.Handlers.Tools,
        Ragex.MCP.Handlers.Prompts,
        Ragex.MCP.Handlers.Resources,
        Ragex.MCP.Handlers.SCIPTools
      ],
      "Image Processing": [
        Ragex.Image,
        Ragex.MCP.Handlers.ImageTools
      ],
      RAG: [
        Ragex.Agent.Core,
        Ragex.Agent.Executor,
        Ragex.Agent.Memory,
        Ragex.Agent.Memory.Session,
        Ragex.Agent.Report,
        Ragex.Agent.StreamConsumer,
        Ragex.Agent.ToolSchema,
        Ragex.RAG.ContextBuilder,
        Ragex.RAG.Pipeline,
        Ragex.RAG.PromptTemplate,
        Ragex.Retrieval.Evaluator,
        Ragex.Retrieval.Hybrid,
        Ragex.Retrieval.Reranker,
        Ragex.Retrieval.Strategies,
        Ragex.Retrieval.CrossLanguage,
        Ragex.Retrieval.MetaASTRanker,
        Ragex.Retrieval.QueryExpansion,
        Ragex.Search.Keywords
      ],
      API: [
        Ragex.API.Auth,
        Ragex.API.OpenAPI,
        Ragex.API.Router,
        Ragex.API.Server
      ],
      Git: [
        Ragex.Git.Backend,
        Ragex.Git.Backend.CLI,
        Ragex.Git.Backend.Egit,
        Ragex.Git.Blame,
        Ragex.Git.BlameEntry,
        Ragex.Git.CoChange,
        Ragex.Git.Commit,
        Ragex.Git.Diff,
        Ragex.Git.Enricher,
        Ragex.Git.Log,
        Ragex.Git.PR,
        Ragex.Git.PR.PRInfo,
        Ragex.Git.Repo,
        Ragex.Git.RepoServer
      ],
      "Code Analysis": [
        Ragex.Analyzers.Elixir,
        Ragex.Analyzers.Erlang,
        Ragex.Analyzers.Python,
        Ragex.Analyzers.JavaScript,
        Ragex.Analyzers.Ruby,
        Ragex.Analyzers.DeeperIndexing,
        Ragex.Analyzers.Detector,
        Ragex.Analyzers.MetaASTExtractor,
        Ragex.Analyzers.SCIP.Adapter,
        Ragex.Analyzers.SCIP.Indexer,
        Ragex.Analyzers.SCIP.Parser,
        Ragex.Analyzers.SCIP.Registry
      ],
      "Store & Knowledge Graph": [
        Ragex.Dllb.Adapter,
        Ragex.Dllb.ProjectManager,
        Ragex.Graph.Algorithms,
        Ragex.Graph.Persistence,
        Ragex.Graph.Store,
        Ragex.Store.Backend,
        Ragex.Store.Backend.Dllb,
        Ragex.Store.Backend.ETS,
        Ragex.VectorStore
      ],
      "Embeddings & ML": [
        Ragex.Embeddings.Behaviour,
        Ragex.Embeddings.Bumblebee,
        Ragex.Embeddings.Chunker,
        Ragex.Embeddings.FileTracker,
        Ragex.Embeddings.Generator,
        Ragex.Embeddings.Helper,
        Ragex.Embeddings.ModelRegistry,
        Ragex.Embeddings.Persistence,
        Ragex.Embeddings.Registry,
        Ragex.Embeddings.TextGenerator
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
        Ragex.Editor.Refactor.MetaAST,
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
        Ragex.Editor.Validators.Ruby,
        Ragex.Editor.Visualize
      ],
      "Code Analysis & Quality": [
        Ragex.Analysis.ASTLocationExtractor,
        Ragex.Analysis.BusinessLogic,
        Ragex.Analysis.Cache,
        Ragex.Analysis.Cohesion,
        Ragex.Analysis.DeadCode,
        Ragex.Analysis.DeadCode.AIRefiner,
        Ragex.Analysis.DependencyGraph,
        Ragex.Analysis.DependencyGraph.AIInsights,
        Ragex.Analysis.Duplication,
        Ragex.Analysis.Duplication.AIAnalyzer,
        Ragex.Analysis.Impact,
        Ragex.Analysis.LocationEnricher,
        Ragex.Analysis.LocationPreservation,
        Ragex.Analysis.MetaCredoBridge,
        Ragex.Analysis.Runner,
        Ragex.Analysis.Semantic,
        Ragex.Analysis.StateAudit,
        Ragex.Analysis.Suggestions,
        Ragex.Analysis.Suggestions.Patterns,
        Ragex.Analysis.Suggestions.Ranker,
        Ragex.Analysis.Suggestions.Actions,
        Ragex.Analysis.Suggestions.RAGAdvisor,
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
        Ragex.CLI.Chat,
        Ragex.CLI.EditorConfig,
        Ragex.CLI.Output,
        Ragex.CLI.Progress,
        Ragex.CLI.Prompt
      ],
      Utilities: [
        Ragex.URLAnalyzer,
        Ragex.URLAnalyzer.Classifier,
        Ragex.URLAnalyzer.GitFetcher,
        Ragex.URLAnalyzer.Report,
        Ragex.URLAnalyzer.WebFetcher,
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
