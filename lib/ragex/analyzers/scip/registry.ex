defmodule Ragex.Analyzers.SCIP.Registry do
  @moduledoc """
  Maps project marker files to languages and their SCIP indexer tools.

  Detects which languages are present in a project directory by looking
  for marker files (e.g. `go.mod` -> Go, `Cargo.toml` -> Rust), and
  knows which SCIP indexer binary to run for each language.

  ## Supported Languages

  | Language     | Marker File(s)           | Indexer Binary     | Extensions        |
  |-------------|--------------------------|-------------------|-------------------|
  | Go          | `go.mod`                 | `scip-go`         | `.go`             |
  | Rust        | `Cargo.toml`             | `rust-analyzer`   | `.rs`             |
  | Java        | `pom.xml`, `build.gradle`| `scip-java`       | `.java`           |
  | Kotlin      | `build.gradle.kts`       | `scip-java`       | `.kt`, `.kts`     |
  | Scala       | `build.sbt`              | `scip-java`       | `.scala`          |
  | C/C++       | `CMakeLists.txt`         | `scip-clang`      | `.c`, `.cpp`, `.h`|
  | C#          | `*.csproj`, `*.sln`      | `scip-dotnet`     | `.cs`             |
  | Ruby        | `Gemfile`                | `scip-ruby`       | `.rb`             |
  | Dart        | `pubspec.yaml`           | `scip-dart`       | `.dart`           |
  | PHP         | `composer.json`          | `scip-php`        | `.php`            |

  Languages already handled natively by Ragex (Elixir, Erlang, Python,
  JavaScript/TypeScript) are excluded -- Ragex's own analyzers or
  Metastatic provide deeper AST access for those.
  """

  @type language_info :: %{
          language: String.t(),
          indexer: String.t(),
          indexer_args: [String.t()],
          extensions: [String.t()],
          marker_files: [String.t()]
        }

  @languages [
    %{
      language: "go",
      indexer: "scip-go",
      indexer_args: [],
      extensions: [".go"],
      marker_files: ["go.mod"]
    },
    %{
      language: "rust",
      indexer: "rust-analyzer",
      indexer_args: ["scip", "."],
      extensions: [".rs"],
      marker_files: ["Cargo.toml"]
    },
    %{
      language: "java",
      indexer: "scip-java",
      indexer_args: ["index"],
      extensions: [".java"],
      marker_files: ["pom.xml", "build.gradle"]
    },
    %{
      language: "kotlin",
      indexer: "scip-java",
      indexer_args: ["index"],
      extensions: [".kt", ".kts"],
      marker_files: ["build.gradle.kts"]
    },
    %{
      language: "scala",
      indexer: "scip-java",
      indexer_args: ["index"],
      extensions: [".scala"],
      marker_files: ["build.sbt"]
    },
    %{
      language: "c_cpp",
      indexer: "scip-clang",
      indexer_args: [],
      extensions: [".c", ".cpp", ".cc", ".cxx", ".h", ".hpp"],
      marker_files: ["CMakeLists.txt", "compile_commands.json"]
    },
    %{
      language: "csharp",
      indexer: "scip-dotnet",
      indexer_args: [],
      extensions: [".cs"],
      marker_files: ["*.csproj", "*.sln"]
    },
    %{
      language: "ruby",
      indexer: "scip-ruby",
      indexer_args: [],
      extensions: [".rb"],
      marker_files: ["Gemfile"]
    },
    %{
      language: "dart",
      indexer: "scip-dart",
      indexer_args: [],
      extensions: [".dart"],
      marker_files: ["pubspec.yaml"]
    },
    %{
      language: "php",
      indexer: "scip-php",
      indexer_args: [],
      extensions: [".php"],
      marker_files: ["composer.json"]
    }
  ]

  @doc "Returns all known SCIP-supported language definitions."
  @spec all_languages() :: [language_info()]
  def all_languages, do: @languages

  @doc """
  Detect which SCIP-supported languages are present in a directory.

  Returns a list of language info maps for each detected language.
  """
  @spec detect_languages(String.t()) :: [language_info()]
  def detect_languages(project_dir) do
    entries =
      case File.ls(project_dir) do
        {:ok, list} -> list
        _ -> []
      end

    Enum.filter(@languages, fn lang ->
      Enum.any?(lang.marker_files, fn marker ->
        if String.contains?(marker, "*") do
          # Glob pattern (e.g. "*.csproj")
          pattern = String.replace(marker, "*", "")
          Enum.any?(entries, &String.ends_with?(&1, pattern))
        else
          marker in entries
        end
      end)
    end)
  end

  @doc """
  Check which SCIP indexer binaries are available on the system.

  Returns a map of `%{language => %{available: bool, path: String.t() | nil}}`.
  """
  @spec check_indexers() :: %{String.t() => %{available: boolean(), path: String.t() | nil}}
  def check_indexers do
    @languages
    |> Enum.uniq_by(& &1.indexer)
    |> Map.new(fn lang ->
      path = System.find_executable(lang.indexer)
      {lang.language, %{available: path != nil, path: path, indexer: lang.indexer}}
    end)
  end

  @doc "Check if the `scip` CLI is available."
  @spec scip_cli_available?() :: boolean()
  def scip_cli_available? do
    System.find_executable("scip") != nil
  end

  @doc "Returns language info for a given language name, or nil."
  @spec get_language(String.t()) :: language_info() | nil
  def get_language(name) do
    Enum.find(@languages, fn lang -> lang.language == name end)
  end

  @doc "Returns all file extensions handled by SCIP (not by native analyzers)."
  @spec scip_extensions() :: [String.t()]
  def scip_extensions do
    @languages |> Enum.flat_map(& &1.extensions) |> Enum.uniq()
  end
end
