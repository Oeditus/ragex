defmodule Ragex.Cure.Loader do
  @moduledoc """
  Loads the Cure compiler modules from the `cure` escript, without clobbering
  modules the host application already has.

  The released `cure` executable is an escript whose archive embeds Cure's own
  beams together with its dependencies (for example an older Metastatic).
  `Metastatic.Adapters.Cure.ToMeta` has a fallback that extracts that archive
  and force-loads every beam whose path mentions "cure". That replaces the
  host's `Metastatic.Adapters.Cure` with the older embedded copy, which can lack
  functions such as `parse/1`.

  This module is a safer replacement for that fallback: a beam is loaded only
  when no module of that name is already loaded or reachable on the code path.
  Running it before Metastatic's own fallback makes `Cure.Compiler.Lexer` and
  `Cure.Compiler.Parser` available, so the fallback never runs.
  """

  require Logger

  # Set once the compiler has been verified (or fully loaded) while holding the
  # global load lock. Beams are loaded one at a time, so the lexer is visible to
  # other processes well before the rest of the compiler (for example
  # `Cure.Edition`). Without this flag a concurrent caller would see the lexer
  # and start parsing against a half-loaded compiler.
  @ready_key {__MODULE__, :ready}
  @lock {__MODULE__, :load}

  @doc """
  Returns `true` when the Cure compiler has been fully loaded or verified as
  loadable by `ensure_loaded/0`.

  This is deliberately conservative: it never returns `true` while another
  process is still in the middle of loading the compiler.
  """
  @spec loaded?() :: boolean()
  def loaded?, do: :persistent_term.get(@ready_key, false)

  @doc """
  Ensures the Cure compiler is available, loading it from the `cure` escript
  when necessary.

  Concurrent callers are serialized: all of them wait for a single load to
  finish and none returns before every beam has been loaded.

  ## Returns
  - `:ok` when the Cure lexer and parser are available
  - `{:error, :cure_not_available}` otherwise
  """
  @spec ensure_loaded() :: :ok | {:error, :cure_not_available}
  def ensure_loaded do
    if loaded?() do
      :ok
    else
      :global.trans({@lock, self()}, &locked_ensure_loaded/0, [node()], :infinity)
      |> case do
        :aborted -> {:error, :cure_not_available}
        result -> result
      end
    end
  end

  @doc """
  Loads the given `{filename, binary}` entries (as returned by
  `:zip.extract/2` with `:memory`), skipping non-beam files and any module that
  is already loaded or available on the code path.

  Returns the list of modules that were loaded.
  """
  @spec load_beams([{charlist() | String.t(), binary()}]) :: [module()]
  def load_beams(files) when is_list(files) do
    files
    |> Enum.filter(fn {filename, _data} -> beam_file?(filename) end)
    |> Enum.flat_map(&load_beam/1)
  end

  # Private functions

  # Runs while holding the global lock, so no other process is loading beams
  # and the code server state observed here is consistent.
  defp locked_ensure_loaded do
    cond do
      loaded?() ->
        :ok

      compiler_available?() ->
        mark_ready()

      true ->
        load_from_executable()
    end
  end

  defp mark_ready do
    :persistent_term.put(@ready_key, true)
    :ok
  end

  defp compiler_available? do
    Enum.all?(
      [Cure.Compiler.Lexer, Cure.Compiler.Parser],
      &match?({:module, _}, Code.ensure_compiled(&1))
    )
  end

  defp load_from_executable do
    with path when is_binary(path) <- find_executable(),
         {:ok, sections} <- :escript.extract(String.to_charlist(path), []),
         archive when is_binary(archive) <- Keyword.get(sections, :archive),
         {:ok, files} <- :zip.extract(archive, [:memory]) do
      load_beams(files)

      if compiler_available?(), do: mark_ready(), else: {:error, :cure_not_available}
    else
      _ -> {:error, :cure_not_available}
    end
  rescue
    e ->
      Logger.debug("Could not load Cure from escript: #{Exception.message(e)}")
      {:error, :cure_not_available}
  end

  @doc """
  Returns the path to the `cure` escript, or `nil` when none can be found.

  Lookup order, first match wins:

    1. `CURE_HOME` -- `$CURE_HOME/bin/cure`, then `$CURE_HOME/cure`.
    2. `CURE_ESCRIPT` -- an explicit path to the escript itself, for setups where
       the compiler checkout lives somewhere unusual.
    3. `PATH` -- a `cure` executable on the system path.
    4. Local checkouts -- a `cure-lang/cure` or `cure/cure` escript in the working
       directory or any of its ancestors, which is how the Oeditus projects are
       laid out locally.

  Discovery is deliberately *not* cached: the compiler may be built after Ragex
  starts, and a failed lookup must not poison later calls.
  """
  @spec find_executable() :: String.t() | nil
  def find_executable do
    Enum.find(candidates(), &escript?/1)
  end

  defp candidates do
    home_candidates() ++ escript_candidates() ++ path_candidates() ++ checkout_candidates()
  end

  defp home_candidates do
    case System.get_env("CURE_HOME") do
      value when is_binary(value) and value != "" ->
        [Path.join([value, "bin", "cure"]), Path.join(value, "cure")]

      _ ->
        []
    end
  end

  defp escript_candidates do
    case System.get_env("CURE_ESCRIPT") do
      value when is_binary(value) and value != "" -> [value]
      _ -> []
    end
  end

  defp path_candidates do
    case System.find_executable("cure") do
      path when is_binary(path) -> [path]
      nil -> []
    end
  end

  # Local checkouts keep the escript at the repository root. Walking up from the
  # working directory covers both a sibling `../cure-lang` and a nested layout.
  defp checkout_candidates do
    File.cwd!()
    |> ancestor_dirs()
    |> Enum.flat_map(fn dir ->
      [
        Path.join([dir, "cure-lang", "cure"]),
        Path.join([dir, "cure", "cure"])
      ]
    end)
  end

  defp ancestor_dirs(dir) do
    parent = Path.dirname(dir)

    if parent == dir do
      [dir]
    else
      [dir | ancestor_dirs(parent)]
    end
  end

  defp escript?(path) when is_binary(path) do
    File.regular?(path) and escript_file?(path)
  end

  defp escript?(_), do: false

  # Guards against picking up an unrelated file that merely happens to be named
  # `cure` (a directory, a shell wrapper, a source file).
  #
  # The released escript is either a bare BEAM archive (starting with the `ER`
  # magic) or a shebang-prefixed executable (`#!...`) followed by the archive, so
  # both are accepted. A plain text file is rejected.
  defp escript_file?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 2)) do
      {:ok, <<0x45, 0x52>>} -> true
      {:ok, <<0x23, 0x21>>} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp beam_file?(filename), do: filename |> to_string() |> String.ends_with?(".beam")

  defp load_beam({filename, data}) do
    filename = to_string(filename)
    module = filename |> Path.basename(".beam") |> String.to_atom()

    if available?(module) do
      []
    else
      case :code.load_binary(module, String.to_charlist(filename), data) do
        {:module, ^module} ->
          [module]

        {:error, reason} ->
          Logger.debug("Skipped Cure beam #{filename}: #{inspect(reason)}")
          []
      end
    end
  end

  defp available?(module) do
    :code.is_loaded(module) != false or :code.which(module) != :non_existing
  end
end
