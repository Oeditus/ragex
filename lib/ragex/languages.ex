defmodule Ragex.Languages do
  @moduledoc """
  Single source of truth for language support in Ragex.

  Ragex does not maintain its own list of languages. Instead it **derives** its
  registry from `Metastatic.Languages` (which discovers adapters at compile
  time) and merges a small Ragex-local overlay describing the concerns that
  Metastatic knows nothing about:

    * the `Ragex.Editor.Validator` implementation for a language
    * the native fallback analyzer (`Ragex.Analyzers.Behaviour`) used when
      Metastatic parsing fails
    * SCIP indexer metadata for languages Ragex has no native parser for

  ## Adding a language

  * **A language Metastatic already supports** (e.g. `:rust` once an adapter
    exists): it appears here automatically. To give it a validator or native
    analyzer, add an entry to the relevant overlay map below.
  * **A language only Ragex can handle** (via SCIP, e.g. Go, Rust): add
    it to `@scip_languages`. It is surfaced as a language with no Metastatic
    adapter but a SCIP indexer.

  A language can be both. `:java` is the worked example: Metastatic ships a
  `Metastatic.Adapters.Java` adapter (JDK tree API via a subprocess bridge), so
  Java becomes a first-class parseable language with a validator and a native
  fallback analyzer, *and* it keeps its `scip-java` entry for projects that
  prefer precise cross-file symbol indexing. `:ruby` is the same shape.
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

  # Languages handled only through SCIP (no Metastatic adapter). These are
  # surfaced so file discovery and SCIP indexing know about them.
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

  # One descriptor per Metastatic language, enriched with the Ragex overlay
  # (validator, native analyzer) and any matching SCIP indexer metadata.
  @metastatic_descriptors (for %MetastaticLanguage{} = ml <- Metastatic.Languages.all() do
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
                           end)

  # SCIP-only languages (no Metastatic adapter).
  @scip_descriptors (for {lang, %{extensions: exts} = info} <- @scip_languages,
                         not MapSet.member?(
                           MapSet.new(Enum.map(@metastatic_descriptors, & &1.language)),
                           lang
                         ) do
                       %Language{language: lang, scip_indexer: info, extensions: exts}
                     end)

  @languages Enum.sort_by(@metastatic_descriptors ++ @scip_descriptors, & &1.language)

  @by_language Map.new(@languages, fn %Language{language: lang} = l -> {lang, l} end)

  # Detection and file discovery only consider languages Ragex can actually
  # parse (i.e. those with a Metastatic adapter). SCIP-only languages are
  # indexed by their own toolchain and are deliberately *not* part of
  # `detect_language/1` or `supported_extensions/0` -- this preserves the
  # long-standing contract that `detect_language("file.c")` is `:unknown`.
  @extension_map for %Language{language: lang, extensions: exts} <- @metastatic_descriptors,
                     ext <- exts,
                     into: %{},
                     do: {ext, lang}

  @adapter_map for %Language{language: lang, adapter: adapter} <- @languages,
                   is_atom(adapter) and adapter != nil,
                   into: %{},
                   do: {lang, adapter}

  @metastatic_languages_set @metastatic_descriptors
                            |> Enum.map(& &1.language)
                            |> MapSet.new()

  @metastatic_extensions @metastatic_descriptors
                         |> Enum.flat_map(& &1.extensions)
                         |> Enum.uniq()
                         |> Enum.sort()

  @all_extensions @metastatic_extensions

  @documentation_languages for %Language{language: lang, documentation?: true} <- @languages,
                               do: lang

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Returns all language descriptors.

  ## Examples

      iex> is_list(Ragex.Languages.all())
      true
  """
  @spec all() :: [Language.t()]
  def all, do: @languages

  @doc """
  Returns the descriptor for a language, or `nil`.

  ## Examples

      iex> %Ragex.Language{language: :elixir} = Ragex.Languages.get(:elixir)
  """
  @spec get(atom()) :: Language.t() | nil
  def get(language), do: Map.get(@by_language, language)

  @doc "Returns the list of supported language atoms."
  @spec supported_languages() :: [atom()]
  def supported_languages, do: Enum.map(@languages, & &1.language)

  @doc "Returns whether a language is supported."
  @spec supported?(atom()) :: boolean()
  def supported?(language), do: Map.has_key?(@by_language, language)

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
    Map.get(@extension_map, Path.extname(path), :unknown)
  end

  @doc """
  Returns the Metastatic adapter module for a language.

  ## Examples

      iex> Ragex.Languages.get_adapter(:elixir)
      {:ok, Metastatic.Adapters.Elixir}

      iex> Ragex.Languages.get_adapter(:go)
      {:error, {:unsupported_language, :go}}
  """
  @spec get_adapter(atom()) :: {:ok, module()} | {:error, {:unsupported_language, atom()}}
  def get_adapter(language) do
    case Map.fetch(@adapter_map, language) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_language, language}}
    end
  end

  @doc "Returns whether a language has a Metastatic adapter."
  @spec has_adapter?(atom()) :: boolean()
  def has_adapter?(language), do: Map.has_key?(@adapter_map, language)

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
    Enum.filter(@languages, fn %Language{scip_indexer: idx} -> idx != nil end)
  end

  @doc "Returns whether a language describes documents rather than code."
  @spec documentation_language?(atom()) :: boolean()
  def documentation_language?(language), do: language in @documentation_languages

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
    case Map.fetch(@extension_map, extension) do
      {:ok, language} -> documentation_language?(language)
      :error -> false
    end
  end

  @doc "Returns all supported file extensions."
  @spec supported_extensions() :: [String.t()]
  def supported_extensions, do: @all_extensions

  @doc "Returns the file extensions with Metastatic adapter support."
  @spec metastatic_extensions() :: [String.t()]
  def metastatic_extensions, do: @metastatic_extensions

  @doc "Returns whether a language is supported by Metastatic."
  @spec metastatic_language?(atom()) :: boolean()
  def metastatic_language?(language), do: MapSet.member?(@metastatic_languages_set, language)

  @doc "Returns a map of language atom to validator module (only those with validators)."
  @spec validators() :: %{atom() => module()}
  def validators do
    for %Language{language: lang, validator: validator} <- @languages,
        is_atom(validator) and validator != nil,
        into: %{},
        do: {lang, validator}
  end

  @doc "Returns a map of language atom to native analyzer module (only those with analyzers)."
  @spec native_analyzers() :: %{atom() => module()}
  def native_analyzers do
    for %Language{language: lang, native_analyzer: analyzer} <- @languages,
        is_atom(analyzer) and analyzer != nil,
        into: %{},
        do: {lang, analyzer}
  end
end
