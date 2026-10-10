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

  @doc """
  Returns `true` when the Cure lexer and parser are loaded or loadable.
  """
  @spec loaded?() :: boolean()
  def loaded? do
    :code.is_loaded(Cure.Compiler.Lexer) != false or
      (match?({:module, _}, Code.ensure_compiled(Cure.Compiler.Lexer)) and
         match?({:module, _}, Code.ensure_compiled(Cure.Compiler.Parser)))
  end

  @doc """
  Ensures the Cure compiler is available, loading it from the `cure` escript
  when necessary.

  ## Returns
  - `:ok` when the Cure lexer and parser are available
  - `{:error, :cure_not_available}` otherwise
  """
  @spec ensure_loaded() :: :ok | {:error, :cure_not_available}
  def ensure_loaded do
    if loaded?() do
      :ok
    else
      load_from_executable()
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

  defp load_from_executable do
    with path when is_binary(path) <- find_executable(),
         {:ok, sections} <- :escript.extract(String.to_charlist(path), []),
         archive when is_binary(archive) <- Keyword.get(sections, :archive),
         {:ok, files} <- :zip.extract(archive, [:memory]) do
      load_beams(files)

      if loaded?(), do: :ok, else: {:error, :cure_not_available}
    else
      _ -> {:error, :cure_not_available}
    end
  rescue
    e ->
      Logger.debug("Could not load Cure from escript: #{Exception.message(e)}")
      {:error, :cure_not_available}
  end

  defp find_executable do
    candidates =
      case System.get_env("CURE_HOME") do
        home when is_binary(home) and home != "" ->
          [Path.join([home, "bin", "cure"]), Path.join(home, "cure")]

        _ ->
          []
      end

    System.find_executable("cure") || Enum.find(candidates, &File.regular?/1)
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
