defmodule Ragex.CLI.Colors do
  @moduledoc """
  ANSI color helpers for CLI output.

  Provides convenience functions for colored terminal output with support
  for NO_COLOR environment variable.

  ## Examples

      iex> Colors.success("Operation successful!")
      "\\e[32mOperation successful!\\e[0m"

      iex> Colors.error("Something went wrong")
      "\\e[31mSomething went wrong\\e[0m"
  """

  @type color :: :black | :red | :green | :yellow | :blue | :magenta | :cyan | :white
  @type style :: :normal | :bright | :faint | :italic | :underline

  @doc """
  Returns true if colors are enabled.

  Colors are disabled when:
  - NO_COLOR environment variable is set
  - TERM environment variable is "dumb"
  - Output is not a TTY
  """
  @spec enabled?() :: boolean()
  def enabled? do
    cond do
      System.get_env("NO_COLOR") -> false
      System.get_env("TERM") == "dumb" -> false
      not io_tty?() -> false
      true -> true
    end
  end

  @doc """
  Formats text in green for success messages.

  ## Examples

      IO.puts Colors.success("Done!")
  """
  @spec success(String.t()) :: String.t()
  def success(text), do: colorize(text, :green, :bright)

  @doc """
  Formats text in red for error messages.

  ## Examples

      IO.puts Colors.error("Failed!")
  """
  @spec error(String.t()) :: String.t()
  def error(text), do: colorize(text, :red, :bright)

  @doc """
  Formats text in yellow for warning messages.

  ## Examples

      IO.puts Colors.warning("Be careful!")
  """
  @spec warning(String.t()) :: String.t()
  def warning(text), do: colorize(text, :yellow, :bright)

  @doc """
  Formats text in blue for info messages.

  ## Examples

      IO.puts Colors.info("Processing...")
  """
  @spec info(String.t()) :: String.t()
  def info(text), do: colorize(text, :blue, :bright)

  @doc """
  Formats text in cyan for highlight messages.

  ## Examples

      IO.puts Colors.highlight("Important!")
  """
  @spec highlight(String.t()) :: String.t()
  def highlight(text), do: colorize(text, :cyan, :bright)

  @doc """
  Formats text in dim gray for muted messages.

  ## Examples

      IO.puts Colors.muted("(optional)")
  """
  @spec muted(String.t()) :: String.t()
  def muted(text), do: colorize(text, :white, :faint)

  @doc """
  Formats text as a section header with bold cyan.

  ## Examples

      IO.puts Colors.header("Step 1: Analysis")
  """
  @spec header(String.t()) :: String.t()
  def header(text) do
    if enabled?() do
      IO.ANSI.cyan() <> IO.ANSI.bright() <> text <> IO.ANSI.reset()
    else
      text
    end
  end

  @doc """
  Formats text with custom color and style.

  ## Examples

      IO.puts Colors.colorize("Custom", :magenta, :italic)
  """
  @spec colorize(String.t(), color(), style()) :: String.t()
  def colorize(text, color, style \\ :normal)

  def colorize(text, _color, _style) when not is_binary(text), do: to_string(text)

  def colorize(text, color, style) do
    if enabled?() do
      [color_code(color), style_code(style), text, IO.ANSI.reset()]
      |> IO.iodata_to_binary()
    else
      text
    end
  end

  @doc """
  Formats text with bold style.

  ## Examples

      IO.puts Colors.bold("Important")
  """
  @spec bold(String.t()) :: String.t()
  def bold(text) do
    if enabled?() do
      IO.ANSI.bright() <> text <> IO.ANSI.reset()
    else
      text
    end
  end

  @doc """
  Formats text with underline.

  ## Examples

      IO.puts Colors.underline("Link")
  """
  @spec underline(String.t()) :: String.t()
  def underline(text) do
    if enabled?() do
      IO.ANSI.underline() <> text <> IO.ANSI.reset()
    else
      text
    end
  end

  @doc """
  Formats diff additions in green with + prefix.

  ## Examples

      IO.puts Colors.diff_add("+ new line")
  """
  @spec diff_add(String.t()) :: String.t()
  def diff_add(text), do: success("+ " <> text)

  @doc """
  Formats diff deletions in red with - prefix.

  ## Examples

      IO.puts Colors.diff_delete("- old line")
  """
  @spec diff_delete(String.t()) :: String.t()
  def diff_delete(text), do: error("- " <> text)

  @doc """
  Formats diff context in muted color.

  ## Examples

      IO.puts Colors.diff_context("  context line")
  """
  @spec diff_context(String.t()) :: String.t()
  def diff_context(text), do: muted("  " <> text)

  # Private helpers

  defp color_code(:black), do: IO.ANSI.black()
  defp color_code(:red), do: IO.ANSI.red()
  defp color_code(:green), do: IO.ANSI.green()
  defp color_code(:yellow), do: IO.ANSI.yellow()
  defp color_code(:blue), do: IO.ANSI.blue()
  defp color_code(:magenta), do: IO.ANSI.magenta()
  defp color_code(:cyan), do: IO.ANSI.cyan()
  defp color_code(:white), do: IO.ANSI.white()
  defp color_code(_), do: ""

  defp style_code(:bright), do: IO.ANSI.bright()
  defp style_code(:faint), do: IO.ANSI.faint()
  defp style_code(:italic), do: IO.ANSI.italic()
  defp style_code(:underline), do: IO.ANSI.underline()
  defp style_code(:normal), do: IO.ANSI.normal()
  defp style_code(_), do: ""

  defp io_tty? do
    case :io.getopts(:standard_io) do
      opts when is_list(opts) -> Keyword.get(opts, :tty, false)
      _ -> false
    end
  end
end
