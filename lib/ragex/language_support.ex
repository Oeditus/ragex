defmodule Ragex.LanguageSupport do
  @moduledoc """
  Shared language detection, adapter resolution, and parsing utilities.

  Consolidates duplicated `detect_language/1`, `get_adapter/1`, `parse_document/3`,
  and `find_source_files/2` helpers that were previously copy-pasted across
  Security, Smells, BusinessLogic, MetastaticBridge, Semantic, and other modules.

  ## Supported Languages

  - `:elixir` -- `.ex`, `.exs`
  - `:erlang` -- `.erl`, `.hrl`
  - `:python` -- `.py`
  - `:ruby` -- `.rb`
  - `:haskell` -- `.hs`
  - `:javascript` -- `.js`, `.jsx`, `.mjs`, `.cjs`
  - `:typescript` -- `.ts`, `.tsx`
  - `:cure` -- `.cure`
  - `:agda` -- `.agda`, `.lagda`

  ## Usage

      alias Ragex.LanguageSupport

      language = LanguageSupport.detect_language("lib/my_module.ex")
      # => :elixir

      {:ok, adapter} = LanguageSupport.get_adapter(:elixir)
      # => {:ok, Metastatic.Adapters.Elixir}

      {:ok, doc} = LanguageSupport.parse_document(source, :elixir)
  """

  alias Metastatic.{Adapter, Document}
  alias Ragex.Cure.Loader, as: CureLoader

  @type language ::
          :elixir
          | :erlang
          | :python
          | :ruby
          | :haskell
          | :javascript
          | :typescript
          | :cure
          | :agda
          | :unknown

  @extension_map %{
    ".ex" => :elixir,
    ".exs" => :elixir,
    ".erl" => :erlang,
    ".hrl" => :erlang,
    ".py" => :python,
    ".rb" => :ruby,
    ".hs" => :haskell,
    ".js" => :javascript,
    ".jsx" => :javascript,
    ".ts" => :typescript,
    ".tsx" => :typescript,
    ".mjs" => :javascript,
    ".cjs" => :javascript,
    ".cure" => :cure,
    ".agda" => :agda,
    ".lagda" => :agda
  }

  @adapter_map %{
    elixir: Metastatic.Adapters.Elixir,
    erlang: Metastatic.Adapters.Erlang,
    python: Metastatic.Adapters.Python,
    ruby: Metastatic.Adapters.Ruby,
    haskell: Metastatic.Adapters.Haskell,
    javascript: Metastatic.Adapters.JavaScript,
    typescript: Metastatic.Adapters.TypeScript,
    cure: Metastatic.Adapters.Cure,
    agda: Metastatic.Adapters.Agda
  }

  @metastatic_extensions ~w(.ex .exs .erl .hrl .py .rb .hs .js .jsx .ts .tsx .mjs .cjs .cure .agda .lagda)

  @all_extensions Map.keys(@extension_map)

  @doc """
  Detects language from a file path extension.

  ## Examples

      iex> Ragex.LanguageSupport.detect_language("lib/my_module.ex")
      :elixir

      iex> Ragex.LanguageSupport.detect_language("script.py")
      :python

      iex> Ragex.LanguageSupport.detect_language("unknown.xyz")
      :unknown
  """
  @spec detect_language(String.t()) :: language()
  def detect_language(path) when is_binary(path) do
    Map.get(@extension_map, Path.extname(path), :unknown)
  end

  @doc """
  Returns the Metastatic adapter module for a language.

  ## Examples

      iex> Ragex.LanguageSupport.get_adapter(:elixir)
      {:ok, Metastatic.Adapters.Elixir}

      iex> Ragex.LanguageSupport.get_adapter(:javascript)
      {:ok, Metastatic.Adapters.JavaScript}
  """
  @spec get_adapter(language()) :: {:ok, module()} | {:error, {:unsupported_language, language()}}
  def get_adapter(language) do
    case Map.fetch(@adapter_map, language) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_language, language}}
    end
  end

  @doc """
  Parses source code into a `Metastatic.Document` via the appropriate adapter.

  ## Parameters

  - `content` -- source code string
  - `language` -- language atom (or auto-detect via `:path` option)
  - `opts` -- keyword options
    - `:path` -- file path for auto-detection (used only if `language` is not provided)

  ## Examples

      {:ok, doc} = LanguageSupport.parse_document(source, :elixir)
  """
  @spec parse_document(String.t(), language(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def parse_document(content, language, opts \\ [])

  def parse_document(content, :cure, opts) when is_binary(content) do
    _ = CureLoader.ensure_loaded()
    do_parse_document(content, :cure, Keyword.put_new(opts, :preserve_comments, false))
  end

  def parse_document(content, language, opts)
      when is_binary(content) and language in [:javascript, :typescript] do
    case parse_vendored_js(content, language, opts) do
      {:ok, %Document{} = doc} ->
        {:ok, doc}

      _ ->
        do_parse_document(content, language, opts)
    end
  end

  def parse_document(content, language, opts) when is_binary(content) do
    do_parse_document(content, language, opts)
  end

  defp do_parse_document(content, language, opts) do
    with {:ok, adapter} <- get_adapter(language) do
      res =
        if function_exported?(adapter, :abstract, 3) do
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(adapter, :abstract, [content, language, opts])
        else
          Adapter.abstract(adapter, content, language)
        end

      case res do
        {:ok, %Document{} = doc} -> {:ok, doc}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Parses a file into a `Metastatic.Document`.

  Reads the file, detects the language, and parses.

  ## Options

  - `:language` -- override language detection (default: auto-detect from extension)

  ## Examples

      {:ok, doc} = LanguageSupport.parse_file("lib/my_module.ex")
  """
  @spec parse_file(String.t(), keyword()) :: {:ok, Document.t()} | {:error, term()}
  def parse_file(path, opts \\ []) do
    language = Keyword.get(opts, :language, detect_language(path))

    with {:ok, content} <- File.read(path) do
      parse_document(content, language)
    end
  end

  @default_exclude_patterns [
    "node_modules",
    ".git",
    ".hg",
    ".svn",
    "_build",
    "deps",
    "target",
    "dist",
    "build",
    "coverage",
    ".elixir_ls",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".bundle",
    "vendor"
  ]

  @doc "Returns default directory exclusion patterns."
  @spec default_exclude_patterns() :: [String.t()]
  def default_exclude_patterns, do: @default_exclude_patterns

  @doc """
  Checks if a file path should be excluded based on relative path components
  from the root directory and configured exclusion patterns.
  """
  @spec should_exclude?(String.t(), String.t(), [String.t()]) :: boolean()
  def should_exclude?(file_path, root_dir, exclude_patterns \\ @default_exclude_patterns) do
    rel_path = Path.relative_to(file_path, root_dir)
    segments = Path.split(rel_path)

    Enum.any?(segments, fn segment ->
      segment in exclude_patterns or
        (String.starts_with?(segment, ".") and segment not in [".", ".."])
    end)
  end

  @doc """
  Finds supported source files in a directory.

  ## Options

  - `:recursive` -- recursively search subdirectories (default: `true`)
  - `:metastatic_only` -- only include languages with Metastatic adapters (default: `false`)
  - `:exclude_patterns` -- patterns/directories to exclude (default: common build/deps dirs)

  ## Examples

      {:ok, files} = LanguageSupport.find_source_files("lib/")
      {:ok, files} = LanguageSupport.find_source_files("lib/", metastatic_only: true)
  """
  @spec find_source_files(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def find_source_files(path, opts \\ []) do
    cond do
      File.regular?(path) ->
        {:ok, [path]}

      File.dir?(path) ->
        recursive = Keyword.get(opts, :recursive, true)
        metastatic_only = Keyword.get(opts, :metastatic_only, false)
        exclude_patterns = Keyword.get(opts, :exclude_patterns, @default_exclude_patterns)

        extensions =
          if metastatic_only do
            @metastatic_extensions
          else
            @all_extensions
          end

        glob = Enum.map_join(extensions, ",", &String.trim_leading(&1, "."))

        pattern =
          if recursive do
            Path.join([path, "**", "*.{#{glob}}"])
          else
            Path.join([path, "*.{#{glob}}"])
          end

        files =
          Path.wildcard(pattern)
          |> Enum.reject(&should_exclude?(&1, path, exclude_patterns))

        {:ok, files}

      true ->
        {:error, {:not_found, path}}
    end
  rescue
    e -> {:error, {:wildcard_failed, e}}
  end

  @doc """
  Returns the list of all supported file extensions.
  """
  @spec supported_extensions() :: [String.t()]
  def supported_extensions, do: @all_extensions

  @doc """
  Returns the list of file extensions with Metastatic adapter support.
  """
  @spec metastatic_extensions() :: [String.t()]
  def metastatic_extensions, do: @metastatic_extensions

  @doc """
  Returns whether a language has a Metastatic adapter.
  """
  @spec has_adapter?(language()) :: boolean()
  def has_adapter?(language), do: Map.has_key?(@adapter_map, language)

  defp parse_vendored_js(content, language, _opts) do
    parser_script = vendored_js_parser_path()

    if parser_script && File.exists?(parser_script) && System.find_executable("node") != nil do
      temp_path =
        Path.join(
          System.tmp_dir!(),
          "ragex_js_#{System.unique_integer([:positive, :monotonic])}.js"
        )

      File.write!(temp_path, content)

      try do
        case System.cmd("node", [parser_script, temp_path],
               cd: Path.dirname(parser_script),
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            case Jason.decode(output) do
              {:ok, %{"ok" => true, "ast" => ast}} ->
                adapter =
                  if language == :typescript,
                    do: Metastatic.Adapters.TypeScript,
                    else: Metastatic.Adapters.JavaScript

                case adapter.to_meta(ast) do
                  {:ok, meta_ast, metadata} ->
                    {:ok, Document.new(meta_ast, language, metadata, content)}

                  error ->
                    error
                end

              {:ok, %{"ok" => false, "error" => error}} ->
                {:error, format_js_error(error)}

              {:error, reason} ->
                {:error, {:json_decode_error, reason}}
            end

          {err_output, exit_code} ->
            {:error, {:node_error, exit_code, err_output}}
        end
      rescue
        e -> {:error, {:exception, Exception.message(e)}}
      after
        File.rm(temp_path)
      end
    else
      {:error, :vendored_parser_unavailable}
    end
  end

  defp vendored_js_parser_path do
    priv_dir =
      try do
        Application.app_dir(:ragex, "priv")
      rescue
        _ -> "priv"
      end

    candidate = Path.join([priv_dir, "parsers", "javascript", "parser.js"])

    if File.exists?(candidate) do
      candidate
    else
      alt = Path.join([priv_dir, "js_parser", "parser.js"])
      if File.exists?(alt), do: alt, else: nil
    end
  end

  defp format_js_error(%{"msg" => msg, "lineno" => line, "col" => col}) do
    "SyntaxError at line #{line}: #{msg} (#{line}:#{col})"
  end

  defp format_js_error(error), do: inspect(error)
end
