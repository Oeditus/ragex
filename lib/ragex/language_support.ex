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
  - `:javascript` -- `.js`, `.jsx`, `.ts`, `.tsx`, `.mjs`, `.cjs`

  Note: JavaScript has no Metastatic adapter yet; `get_adapter/1` returns an error for it.

  ## Usage

      alias Ragex.LanguageSupport

      language = LanguageSupport.detect_language("lib/my_module.ex")
      # => :elixir

      {:ok, adapter} = LanguageSupport.get_adapter(:elixir)
      # => {:ok, Metastatic.Adapters.Elixir}

      {:ok, doc} = LanguageSupport.parse_document(source, :elixir)
  """

  alias Metastatic.{Adapter, Document}

  @type language :: :elixir | :erlang | :python | :ruby | :haskell | :javascript | :unknown

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
    ".ts" => :javascript,
    ".tsx" => :javascript,
    ".mjs" => :javascript,
    ".cjs" => :javascript
  }

  @adapter_map %{
    elixir: Metastatic.Adapters.Elixir,
    erlang: Metastatic.Adapters.Erlang,
    python: Metastatic.Adapters.Python,
    ruby: Metastatic.Adapters.Ruby,
    haskell: Metastatic.Adapters.Haskell
  }

  @metastatic_extensions ~w(.ex .exs .erl .hrl .py .rb .hs)

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
      {:error, {:unsupported_language, :javascript}}
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
  def parse_document(content, language, _opts \\ []) when is_binary(content) do
    with {:ok, adapter} <- get_adapter(language) do
      case Adapter.abstract(adapter, content, language) do
        {:ok, %Document{} = doc} -> {:ok, doc}
        {:error, _} = error -> error
        other -> {:error, {:unexpected_parse_result, other}}
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

  @doc """
  Finds supported source files in a directory.

  ## Options

  - `:recursive` -- recursively search subdirectories (default: `true`)
  - `:metastatic_only` -- only include languages with Metastatic adapters (default: `false`)

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

        {:ok, Path.wildcard(pattern)}

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
end
