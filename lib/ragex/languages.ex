defmodule Ragex.Languages do
  @moduledoc """
  Single source of truth for language support in Ragex.

  Ragex does not maintain its own list of languages. Instead it **derives** its
  registry dynamically from `Metastatic.Languages` (built-in adapters plus any
  runtime-registered third-party plugins) and merges a small Ragex-local overlay
  describing the concerns that Metastatic knows nothing about:

    * the `Ragex.Editor.Validator` implementation for a language
    * the native fallback analyzer (`Ragex.Analyzers.Behaviour`) used when
      Metastatic parsing fails
    * SCIP indexer metadata for languages Ragex has no native parser for

  ## Adding a language

  * **A language Metastatic already supports** (e.g. `:go` and `:rust`): it
    appears here automatically. To give it a validator or native analyzer, add
    an entry to the relevant overlay map below.
  * **A language only Ragex can handle** (via SCIP, e.g. `:c_cpp`, `:kotlin`):
    add it to `@scip_languages`. It is surfaced as a language with no
    Metastatic adapter but a SCIP indexer.

  A language can be both. `:java` is the worked example: Metastatic ships a
  `Metastatic.Adapters.Java` adapter (JDK tree API via a subprocess bridge), so
  Java becomes a first-class parseable language with a validator and a native
  fallback analyzer, *and* it keeps its `scip-java` entry for projects that
  prefer precise cross-file symbol indexing. `:ruby` is the same shape: the
  Metastatic adapter parses and (since 0.44) round-trips, while `scip-ruby`
  remains available for precise cross-file indexing.

  `:haskell` and `:lfe` are the two languages Ragex inherits from Metastatic
  0.40 with no overlay entry at all: neither has a Ragex validator or native
  fallback analyzer, so they are surfaced exactly as Metastatic describes them
  (adapter, extensions, `experimental?: true`). They are the worked example of
  the first bullet above -- adding a language to Metastatic requires no Ragex
  change unless a Ragex-only concern is wanted.

  ## Examples

      iex> Ragex.Languages.supported?(:elixir)
      true

      iex> Ragex.Languages.detect_language("lib/my_module.ex")
      :elixir

      iex> Ragex.Languages.get_adapter(:python)
      {:ok, Metastatic.Adapters.Python}
  """

  alias Metastatic.Language, as: MetastaticLanguage
  alias Ragex.Language

  # ── Ragex-local overlay ─────────────────────────────────────────────
  #
  # These describe concerns that live in Ragex, not Metastatic. Kept as plain
  # data so the registry is a deterministic compile-time constant.

  @validators %{
    elixir: Ragex.Editor.Validators.Elixir,
    erlang: Ragex.Editor.Validators.Erlang,
    python: Ragex.Editor.Validators.Python,
    ruby: Ragex.Editor.Validators.Ruby,
    javascript: Ragex.Editor.Validators.Javascript,
    typescript: Ragex.Editor.Validators.Javascript,
    java: Ragex.Editor.Validators.Java,
    rust: Ragex.Editor.Validators.Rust,
    cure: Ragex.Editor.Validators.Cure,
    agda: Ragex.Editor.Validators.Agda,
    markdown: Ragex.Editor.Validators.Markdown
  }

  @native_analyzers %{
    elixir: Ragex.Analyzers.Elixir,
    erlang: Ragex.Analyzers.Erlang,
    python: Ragex.Analyzers.Python,
    ruby: Ragex.Analyzers.Ruby,
    javascript: Ragex.Analyzers.JavaScript,
    typescript: Ragex.Analyzers.JavaScript,
    java: Ragex.Analyzers.Java
  }

  # SCIP indexer metadata. A language here may *also* have a Metastatic
  # adapter — `:java` and `:rust` both do. In that case the adapter provides
  # parsing, analysis and validation, while the SCIP entry provides precise
  # cross-file symbol indexing for projects that want it. The two are
  # complementary, not alternatives.
  @scip_languages %{
    go: %{indexer: "scip-go", indexer_args: [], extensions: [".go"], marker_files: ["go.mod"]},
    rust: %{
      indexer: "rust-analyzer",
      indexer_args: ["scip", "."],
      extensions: [".rs"],
      marker_files: ["Cargo.toml"]
    },
    java: %{
      indexer: "scip-java",
      indexer_args: ["index"],
      extensions: [".java"],
      marker_files: ["pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle"]
    },
    kotlin: %{
      indexer: "scip-java",
      indexer_args: ["index"],
      extensions: [".kt", ".kts"],
      marker_files: ["build.gradle.kts"]
    },
    scala: %{
      indexer: "scip-java",
      indexer_args: ["index"],
      extensions: [".scala"],
      marker_files: ["build.sbt"]
    },
    c_cpp: %{
      indexer: "scip-clang",
      indexer_args: [],
      extensions: [".c", ".cpp", ".cc", ".cxx", ".h", ".hpp"],
      marker_files: ["CMakeLists.txt", "compile_commands.json"]
    },
    csharp: %{
      indexer: "scip-dotnet",
      indexer_args: [],
      extensions: [".cs"],
      marker_files: ["*.csproj", "*.sln"]
    },
    dart: %{
      indexer: "scip-dart",
      indexer_args: [],
      extensions: [".dart"],
      marker_files: ["pubspec.yaml"]
    },
    php: %{
      indexer: "scip-php",
      indexer_args: [],
      extensions: [".php"],
      marker_files: ["composer.json"]
    },
    # Ruby has a Metastatic adapter *and* a SCIP indexer. It is listed here so
    # the SCIP registry keeps its historical 10-language set; the descriptor
    # merge below attaches the SCIP info to the metastatic `:ruby` descriptor.
    ruby: %{
      indexer: "scip-ruby",
      indexer_args: [],
      extensions: [".rb"],
      marker_files: ["Gemfile"]
    }
  }

  # ── Build the registry by deriving from Metastatic ──────────────────

  # SCIP-only languages (languages with no Metastatic adapter at compile time,
  # or fallback descriptors when queried directly). Metastatic languages are
  # queried dynamically from `Metastatic.Languages` so runtime-registered
  # third-party plugins are visible immediately.
  @scip_only_descriptors (for {lang, %{extensions: exts} = info} <- @scip_languages,
                              not Metastatic.Languages.supported?(lang) do
                            %Language{language: lang, scip_indexer: info, extensions: exts}
                          end)

  @scip_only_by_language Map.new(@scip_only_descriptors, fn %Language{language: lang} = l ->
                           {lang, l}
                         end)

  defp merge_overlay(%MetastaticLanguage{} = ml) do
    %Language{
      language: ml.language,
      adapter: ml.adapter,
      validator: Map.get(@validators, ml.language),
      native_analyzer: Map.get(@native_analyzers, ml.language),
      scip_indexer: Map.get(@scip_languages, ml.language),
      extensions: ml.extensions,
      experimental?: ml.experimental?,
      documentation?: ml.documentation?
    }
  end

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Returns all language descriptors.

  ## Examples

      iex> is_list(Ragex.Languages.all())
      true
  """
  @spec all() :: [Language.t()]
  def all do
    metastatic_langs = Metastatic.Languages.all()
    metastatic_set = MapSet.new(metastatic_langs, & &1.language)

    metastatic_descriptors = Enum.map(metastatic_langs, &merge_overlay/1)

    scip_descriptors =
      Enum.reject(@scip_only_descriptors, fn %Language{language: lang} ->
        MapSet.member?(metastatic_set, lang)
      end)

    Enum.sort_by(metastatic_descriptors ++ scip_descriptors, & &1.language)
  end

  @doc """
  Returns the descriptor for a language, or `nil`.

  ## Examples

      iex> %Ragex.Language{language: :elixir} = Ragex.Languages.get(:elixir)
  """
  @spec get(atom()) :: Language.t() | nil
  def get(language) when is_atom(language) do
    case Metastatic.Languages.get(language) do
      %MetastaticLanguage{} = ml -> merge_overlay(ml)
      nil -> Map.get(@scip_only_by_language, language)
    end
  end

  @doc "Returns the list of supported language atoms."
  @spec supported_languages() :: [atom()]
  def supported_languages, do: Enum.map(all(), & &1.language)

  @doc "Returns whether a language is supported."
  @spec supported?(atom()) :: boolean()
  def supported?(language) when is_atom(language) do
    Metastatic.Languages.supported?(language) or Map.has_key?(@scip_only_by_language, language)
  end

  @doc """
  Detects the language from a file path extension.

  Returns `:unknown` when the extension is not recognised.

  ## Examples

      iex> Ragex.Languages.detect_language("lib/my_module.ex")
      :elixir

      iex> Ragex.Languages.detect_language("unknown.xyz")
      :unknown
  """
  @spec detect_language(String.t()) :: atom()
  def detect_language(path) when is_binary(path) do
    case Metastatic.Languages.detect_language(path) do
      {:ok, lang} -> lang
      {:error, _} -> :unknown
    end
  end

  @doc """
  Returns the Metastatic adapter module for a language.

  ## Examples

      iex> Ragex.Languages.get_adapter(:elixir)
      {:ok, Metastatic.Adapters.Elixir}

      iex> Ragex.Languages.get_adapter(:go)
      {:ok, Metastatic.Adapters.Go}

      iex> Ragex.Languages.get_adapter(:c_cpp)
      {:error, {:unsupported_language, :c_cpp}}
  """
  @spec get_adapter(atom()) :: {:ok, module()} | {:error, {:unsupported_language, atom()}}
  def get_adapter(language) when is_atom(language) do
    case Metastatic.Languages.get_adapter(language) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, _} -> {:error, {:unsupported_language, language}}
    end
  end

  @doc "Returns whether a language has a Metastatic adapter."
  @spec has_adapter?(atom()) :: boolean()
  def has_adapter?(language) when is_atom(language) do
    Metastatic.Languages.supported?(language)
  end

  @doc """
  Returns whether the Metastatic adapter toolchain for `language` is available
  in the current environment.

  Delegates to `Metastatic.Adapter.available?/1` (standardized across all
  adapters in Metastatic 0.45). Returns `false` for SCIP-only or unknown
  languages that have no Metastatic adapter.

  ## Examples

      iex> Ragex.Languages.available?(:elixir)
      true

      iex> Ragex.Languages.available?(:c_cpp)
      false
  """
  @spec available?(atom()) :: boolean()
  def available?(language) when is_atom(language) do
    case get_adapter(language) do
      {:ok, adapter} -> Metastatic.Adapter.available?(adapter)
      {:error, _} -> false
    end
  end

  @doc "Returns the validator module for a language, or `nil`."
  @spec validator(atom()) :: module() | nil
  def validator(language) do
    case get(language) do
      %Language{validator: validator} -> validator
      nil -> nil
    end
  end

  @doc "Returns the native fallback analyzer for a language, or `nil`."
  @spec native_analyzer(atom()) :: module() | nil
  def native_analyzer(language) do
    case get(language) do
      %Language{native_analyzer: analyzer} -> analyzer
      nil -> nil
    end
  end

  @doc "Returns the SCIP indexer metadata for a language, or `nil`."
  @spec scip_indexer(atom()) :: Language.scip_indexer() | nil
  def scip_indexer(language) do
    case get(language) do
      %Language{scip_indexer: indexer} -> indexer
      nil -> nil
    end
  end

  @doc "Returns all languages that have a SCIP indexer."
  @spec scip_languages() :: [Language.t()]
  def scip_languages do
    Enum.filter(all(), fn %Language{scip_indexer: idx} -> idx != nil end)
  end

  @doc "Returns whether a language describes documents rather than code."
  @spec documentation_language?(atom()) :: boolean()
  def documentation_language?(language) when is_atom(language) do
    Metastatic.Languages.documentation?(language)
  end

  @doc """
  Returns whether a file path points at a documentation-language file.

  ## Examples

      iex> Ragex.Languages.documentation_file?("README.md")
      true

      iex> Ragex.Languages.documentation_file?("lib/my_module.ex")
      false
  """
  @spec documentation_file?(String.t()) :: boolean()
  def documentation_file?(path) when is_binary(path) do
    path |> detect_language() |> documentation_language?()
  end

  @doc """
  Returns whether a file extension belongs to a documentation language.

  ## Examples

      iex> Ragex.Languages.documentation_extension?(".md")
      true

      iex> Ragex.Languages.documentation_extension?(".ex")
      false
  """
  @spec documentation_extension?(String.t()) :: boolean()
  def documentation_extension?(extension) when is_binary(extension) do
    case Metastatic.Languages.detect_language("file" <> extension) do
      {:ok, language} -> Metastatic.Languages.documentation?(language)
      {:error, _} -> false
    end
  end

  @doc "Returns all supported file extensions."
  @spec supported_extensions() :: [String.t()]
  def supported_extensions, do: Metastatic.Languages.supported_extensions()

  @doc "Returns the file extensions with Metastatic adapter support."
  @spec metastatic_extensions() :: [String.t()]
  def metastatic_extensions, do: Metastatic.Languages.supported_extensions()

  @doc "Returns whether a language is supported by Metastatic."
  @spec metastatic_language?(atom()) :: boolean()
  def metastatic_language?(language) when is_atom(language) do
    Metastatic.Languages.supported?(language)
  end

  @doc "Returns a map of language atom to validator module (only those with validators)."
  @spec validators() :: %{atom() => module()}
  def validators, do: @validators

  @doc "Returns a map of language atom to native analyzer module (only those with analyzers)."
  @spec native_analyzers() :: %{atom() => module()}
  def native_analyzers, do: @native_analyzers
end
