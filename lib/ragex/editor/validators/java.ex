defmodule Ragex.Editor.Validators.Java do
  @moduledoc """
  Java code validator.

  Validates Java syntax with the JDK's own compiler API through
  `Metastatic.Adapters.Java.parse/1`, so a file is reported as valid exactly
  when `javac` would accept it. This catches syntax errors *and* structural
  problems a regex or a brace counter would miss (unbalanced generics,
  malformed annotations, illegal modifiers).

  ## Why not `javac` directly?

  `javac -Xstdout` needs a writable output directory and emits `.class` files
  as a side effect; the Metastatic bridge parses in memory and needs nothing
  but a `java` executable. It also reports the error line, which is what the
  editor pipeline needs to place a diagnostic.

  ## When no JDK is installed

  Validation degrades to a `:warning` explaining that Java syntax could not be
  checked, rather than failing the edit. Ragex must never block an edit
  because a toolchain is missing.
  """

  @behaviour Ragex.Editor.Validator

  alias Metastatic.Adapters.Java, as: JavaAdapter
  alias Ragex.Editor.Types

  @impl true
  def validate(content, _opts \\ []) when is_binary(content) do
    case JavaAdapter.parse(content) do
      {:ok, _ast} ->
        {:ok, :valid}

      {:error, reason} ->
        {:error, [format_error(reason)]}
    end
  rescue
    e ->
      {:error,
       [
         Types.validation_error("Java validation failed: #{Exception.message(e)}",
           severity: :error
         )
       ]}
  end

  @impl true
  def can_validate?(path) when is_binary(path) do
    Path.extname(path) == ".java"
  end

  def can_validate?(_), do: false

  # Private

  # The bridge reports `"SyntaxError at line 12: <message>"`. Pull the line out
  # when present so the editor can point at it; otherwise keep the message and
  # mark it as a warning (a missing JDK is not the user's syntax error).
  defp format_error(reason) when is_binary(reason) do
    case Regex.run(~r/^SyntaxError at line (\d+): (.*)$/s, reason) do
      [_, line, message] ->
        Types.validation_error(message, line: parse_int(line), severity: :error)

      _ ->
        severity = if toolchain_missing?(reason), do: :warning, else: :error
        Types.validation_error(reason, severity: severity)
    end
  end

  defp toolchain_missing?(reason) do
    String.contains?(reason, "Java parser unavailable") or
      String.contains?(reason, "no `java` executable") or
      String.contains?(reason, "bridge")
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> nil
    end
  end
end
