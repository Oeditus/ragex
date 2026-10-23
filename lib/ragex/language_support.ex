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
          | :march
          | :unknown

  @extension_map %{
    ".ex" => :elixir,
    ".exs" => :elixir,
    ".erl" => :erlang,
    ".hrl" => :erlang,
    ".py" => :python,
    ".rb" => :ruby,
    ".hs" => :haskell,
    ".lhs" => :haskell,
    ".js" => :javascript,
    ".jsx" => :javascript,
    ".ts" => :typescript,
    ".tsx" => :typescript,
    ".mjs" => :javascript,
    ".cjs" => :javascript,
    ".cure" => :cure,
    ".agda" => :agda,
    ".lagda" => :agda,
    ".march" => :march,
    ".mch" => :march
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
    agda: Metastatic.Adapters.Agda,
    march: Metastatic.Adapters.March
  }

  @metastatic_extensions ~w(.ex .exs .erl .hrl .py .rb .hs .lhs .js .jsx .ts .tsx .mjs .cjs .cure .agda .lagda .march .mch)

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
      # Metastatic's semantic pattern tables are populated by a module-level
      # side effect that only fires at compile time, so they can be empty in
      # any build that loads the beams from disk. Without this the adapter's
      # `Enricher.enrich_tree/2` pass attaches no `:op_kind` metadata and every
      # semantic-analysis feature silently reports zero operations.
      _ = ensure_semantic_patterns()

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

  @semantic_domain_modules [
    Metastatic.Semantic.Domains.Database,
    Metastatic.Semantic.Domains.Http,
    Metastatic.Semantic.Domains.Auth,
    Metastatic.Semantic.Domains.Cache,
    Metastatic.Semantic.Domains.Queue,
    Metastatic.Semantic.Domains.File,
    Metastatic.Semantic.Domains.ExternalApi
  ]

  @semantic_ready_key {__MODULE__, :semantic_ready}

  @doc """
  Ensures Metastatic's semantic operation patterns are registered.

  Metastatic registers its `OpKind` pattern tables from module-level
  `register_all/0` calls at the bottom of each `Metastatic.Semantic.Domains.*`
  module. Elixir only evaluates that kind of top-level side effect while the
  module is being **compiled**, so in any build where the beams are loaded from
  disk (a release, a `mix compile` from a clean `_build`, a dependency compiled
  ahead of time, ...) the tables stay empty and `Enricher.enrich_tree/2`
  silently attaches no `op_kind` metadata at all.

  Empty pattern tables mean semantic analysis degrades to "no operations
  detected" with no error anywhere, so Ragex calls this once during
  application start (see `Ragex.Application`) and again from every code path
  that reads `op_kind`.

  The call is idempotent -- `Metastatic.Semantic.Patterns.register/3` appends
  to the existing list -- so it is guarded by a `:persistent_term` flag to keep
  repeated calls cheap and to avoid growing the tables on every invocation.

  Returns `:ok` even when the domain modules are unavailable, so a Metastatic
  version that reorganises them cannot break startup.
  """
  @spec ensure_semantic_patterns() :: :ok
  def ensure_semantic_patterns do
    if :persistent_term.get(@semantic_ready_key, false) do
      :ok
    else
      Enum.each(@semantic_domain_modules, fn domain ->
        try do
          Code.ensure_loaded(domain)

          if function_exported?(domain, :register_all, 0) do
            domain.register_all()
          end
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

      :persistent_term.put(@semantic_ready_key, true)
      :ok
    end
  end

  @doc """
  Clears the `ensure_semantic_patterns/0` guard so the next call re-registers.

  Intended for tests that clear Metastatic's pattern tables.
  """
  @spec reset_semantic_patterns() :: :ok
  def reset_semantic_patterns do
    :persistent_term.erase(@semantic_ready_key)
    :ok
  end

  defp parse_vendored_js(content, language, _opts) do
    parser_script = vendored_js_parser_path()
    node_bin = find_executable("node")

    if parser_script && File.exists?(parser_script) && node_bin != nil do
      parser_dir = Path.dirname(parser_script)
      _ = ensure_js_dependencies(parser_dir)

      temp_path =
        Path.join(
          System.tmp_dir!(),
          "ragex_js_#{System.unique_integer([:positive, :monotonic])}.js"
        )

      File.write!(temp_path, content)

      try do
        case System.cmd(node_bin, [parser_script, temp_path],
               cd: parser_dir,
               env: subprocess_env(parser_dir),
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            decode_vendored_js_output(output, language, content)

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

  defp decode_vendored_js_output(output, language, content) do
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
  end

  @doc false
  @spec ensure_js_dependencies(String.t()) :: :ok | {:error, term()}
  def ensure_js_dependencies(parser_dir) when is_binary(parser_dir) do
    local_babel = Path.join([parser_dir, "node_modules", "@babel", "parser"])
    home = System.user_home() || ""

    global_babel =
      Path.join([
        home,
        ".local",
        "share",
        "mise",
        "installs",
        "node",
        "latest",
        "lib",
        "node_modules",
        "@babel",
        "parser"
      ])

    npm_bin = find_executable("npm")

    cond do
      File.exists?(local_babel) or File.exists?(global_babel) ->
        :ok

      npm_bin != nil and File.dir?(parser_dir) ->
        case System.cmd(npm_bin, ["install", "--no-audit", "--no-fund"],
               cd: parser_dir,
               env: subprocess_env(parser_dir),
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {err, code} -> {:error, {:npm_install_failed, code, err}}
        end

      true ->
        {:error, :npm_unavailable}
    end
  end

  @doc false
  @spec find_executable(String.t()) :: String.t() | nil
  def find_executable(name) when is_binary(name) do
    case System.find_executable(name) do
      path when is_binary(path) ->
        path

      nil ->
        home = System.user_home() || ""

        [
          Path.join([home, ".local", "share", "mise", "shims", name]),
          Path.join([home, ".local", "bin", name]),
          Path.join(["/usr", "local", "bin", name]),
          Path.join(["/usr", "bin", name])
        ]
        |> Enum.find(&(File.exists?(&1) and not File.dir?(&1)))
    end
  end

  @doc false
  @spec subprocess_env(String.t() | nil) :: [{String.t(), String.t()}]
  def subprocess_env(parser_dir \\ nil) do
    home = System.user_home() || ""
    mise_shims = Path.join([home, ".local", "share", "mise", "shims"])
    local_bin = Path.join([home, ".local", "bin"])
    current_path = System.get_env("PATH") || "/usr/local/bin:/usr/bin:/bin"

    augmented_path =
      [mise_shims, local_bin, current_path]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(":")

    local_node_modules = if parser_dir, do: Path.join(parser_dir, "node_modules"), else: nil

    mise_node_modules =
      Path.join([
        home,
        ".local",
        "share",
        "mise",
        "installs",
        "node",
        "latest",
        "lib",
        "node_modules"
      ])

    node_path =
      [local_node_modules, System.get_env("NODE_PATH"), mise_node_modules]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(":")

    [{"PATH", augmented_path}, {"NODE_PATH", node_path}]
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
