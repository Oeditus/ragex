defmodule Ragex.Editor.Formatter do
  @moduledoc """
  Automatic code formatting integration.

  Provides language-specific formatters that can be run after successful edits.
  Formatters are detected based on file extension and project structure.
  """

  require Logger

  @doc """
  Formats a file using the appropriate language formatter.

  ## Parameters
  - `path`: Path to the file to format
  - `opts`: Options
    - `:language` - Explicit language override
    - `:formatter` - Explicit formatter command

  ## Returns
  - `:ok` if formatting succeeded or no formatter available
  - `{:error, reason}` if formatting failed

  ## Examples

      iex> Formatter.format("lib/module.ex")
      :ok
      
      iex> Formatter.format("script", language: :python)
      :ok
  """
  @spec format(String.t(), keyword()) :: :ok | {:error, term()}
  def format(path, opts \\ []) do
    language = Keyword.get(opts, :language) || detect_language(path)
    formatter = Keyword.get(opts, :formatter) || detect_formatter(language, path)

    case formatter do
      nil ->
        Logger.debug("No formatter available for #{path}")
        :ok

      {command, args} ->
        run_formatter(command, args, path)
    end
  end

  @doc """
  Checks if a formatter is available for the given file or language.

  ## Examples

      iex> Formatter.available?("lib/module.ex")
      true
      
      iex> Formatter.available?("file.txt")
      false
  """
  @spec available?(String.t(), keyword()) :: boolean()
  def available?(path, opts \\ []) do
    language = Keyword.get(opts, :language) || detect_language(path)
    formatter = Keyword.get(opts, :formatter) || detect_formatter(language, path)

    case formatter do
      nil -> false
      {command, _args} -> command_exists?(command)
    end
  end

  # Private functions

  defp detect_language(path) do
    case Path.extname(path) do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".erl" -> :erlang
      ".hrl" -> :erlang
      ".py" -> :python
      ".js" -> :javascript
      ".jsx" -> :javascript
      ".ts" -> :typescript
      ".tsx" -> :typescript
      _ -> nil
    end
  end

  defp detect_formatter(:elixir, path) do
    # Check if we're in a Mix project
    project_root = find_project_root(path, "mix.exs")

    if project_root do
      # Use mix format with project context
      {"mix", ["format", path]}
    else
      # Standalone file formatting
      {"mix", ["format", path]}
    end
  end

  defp detect_formatter(:erlang, path) do
    # Check if we're in a rebar3 project
    project_root = find_project_root(path, "rebar.config")

    if project_root && command_exists?("rebar3") do
      {"rebar3", ["fmt", "-w", path]}
    else
      # No standard Erlang formatter without rebar3
      nil
    end
  end

  defp detect_formatter(:python, _path) do
    # Try black first, then autopep8
    cond do
      command_exists?("black") ->
        {"black", ["--quiet", "--"]}

      command_exists?("autopep8") ->
        {"autopep8", ["--in-place", "--"]}

      true ->
        nil
    end
  end

  defp detect_formatter(:javascript, _path) do
    cond do
      command_exists?("prettier") ->
        {"prettier", ["--write", "--"]}

      command_exists?("eslint") ->
        {"eslint", ["--fix", "--"]}

      true ->
        nil
    end
  end

  defp detect_formatter(:typescript, path) do
    # TypeScript uses same formatters as JavaScript
    detect_formatter(:javascript, path)
  end

  defp detect_formatter(_language, _path), do: nil

  defp run_formatter(command, args, path) do
    # Build full argument list
    full_args = args ++ [path]

    Logger.debug("Running formatter: #{command} #{Enum.join(full_args, " ")}")

    case System.cmd(command, full_args, stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.debug("Successfully formatted #{path}")
        :ok

      {output, exit_code} ->
        error_msg = "Formatter failed (exit #{exit_code}): #{String.trim(output)}"
        Logger.warning(error_msg)
        {:error, error_msg}
    end
  rescue
    e in ErlangError ->
      if e.original == :enoent do
        Logger.warning("Formatter command '#{command}' not found")
        {:error, "Formatter '#{command}' not available"}
      else
        Logger.error("Formatter error: #{Exception.message(e)}")
        {:error, Exception.message(e)}
      end

    e ->
      Logger.error("Formatter error: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp find_project_root(path, marker_file) do
    path
    |> Path.expand()
    |> Path.dirname()
    |> find_project_root_recursive(marker_file)
  end

  defp find_project_root_recursive("/", _marker_file), do: nil

  defp find_project_root_recursive(dir, marker_file) do
    marker_path = Path.join(dir, marker_file)

    if File.exists?(marker_path) do
      dir
    else
      parent = Path.dirname(dir)
      find_project_root_recursive(parent, marker_file)
    end
  end

  defp command_exists?(command) do
    case System.cmd("which", [command], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
