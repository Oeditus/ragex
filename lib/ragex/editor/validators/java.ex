defmodule Ragex.Editor.Validators.Java do
  @moduledoc """
  Java code validator.

  Validates Java syntax with the JDK's own compiler API through
  `Metastatic.Adapters.Java.parse/1`, so a file is reported as valid exactly
  when `javac` would accept it. This catches syntax errors *and* structural
  problems a regex or a brace counter would miss (unbalanced generics,
  malformed annotations, illegal modifiers).

  Additionally enforces Java structural file layout rules:
    * Public class/interface/record/enum name must match the `.java` filename.
    * Declared `package` must match the file's path directory hierarchy.
    * Warns when generic placeholder packages (`com.example`, `org.example`) are used.

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
  def validate(content, opts \\ []) when is_binary(content) do
    case JavaAdapter.parse(content) do
      {:ok, ast} ->
        path = Keyword.get(opts, :path)

        case validate_structural_invariants(ast, path, content) do
          :ok -> {:ok, :valid}
          {:error, errors} -> {:error, errors}
        end

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

  defp validate_structural_invariants(_ast, path, _content) when path in [nil, ""], do: :ok

  defp validate_structural_invariants(ast, path, content) when is_binary(path) do
    errors =
      []
      |> check_public_type_matches_filename(ast, path)
      |> check_package_matches_directory(ast, path, content)
      |> check_placeholder_package(ast, content)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  defp check_public_type_matches_filename(acc, %{"types" => types}, path) when is_list(types) do
    actual_basename = Path.basename(path)

    public_mismatches =
      for %{"modifiers" => mods, "name" => name} = type <- types,
          is_list(mods) and "public" in mods,
          actual_basename != "#{name}.java" do
        kind = String.downcase(type["kind"] || "class")

        Types.validation_error(
          "Public #{kind} '#{name}' must be declared in a file named '#{name}.java', but current file is '#{actual_basename}'",
          severity: :error
        )
      end

    acc ++ public_mismatches
  end

  defp check_public_type_matches_filename(acc, _ast, _path), do: acc

  defp check_package_matches_directory(acc, ast, path, content) do
    package_name = extract_package_name(ast) || extract_package_from_source(content)

    if package_name && should_validate_package_dir?(path) do
      expected_suffix = String.replace(package_name, ".", "/")
      dir = Path.dirname(path)

      if String.ends_with?(dir, expected_suffix) do
        acc
      else
        acc ++
          [
            Types.validation_error(
              "Package '#{package_name}' does not match file path '#{path}'. " <>
                "In Java, classes in package '#{package_name}' must reside in a directory ending with '#{expected_suffix}' " <>
                "(e.g. 'src/main/java/#{expected_suffix}/#{Path.basename(path)}')",
              severity: :error
            )
          ]
      end
    else
      acc
    end
  end

  defp check_placeholder_package(acc, ast, content) do
    package_name = extract_package_name(ast) || extract_package_from_source(content)

    if package_name && String.starts_with?(package_name, ["com.example", "org.example"]) do
      acc ++
        [
          Types.validation_error(
            "Placeholder package '#{package_name}' detected. Ensure this matches your project's root package hierarchy rather than a tutorial placeholder.",
            severity: :warning
          )
        ]
    else
      acc
    end
  end

  defp should_validate_package_dir?(path) do
    # Enforce package path hierarchy if path has directory segments and isn't a root/scratch file
    String.contains?(path, "/") and
      (String.contains?(path, "src/") or
         String.contains?(path, "java/") or
         length(Path.split(path)) > 3)
  end

  defp extract_package_name(%{"package" => %{} = pkg}) do
    flatten_package_expr(pkg)
  end

  defp extract_package_name(_), do: nil

  defp flatten_package_expr(%{"expr" => expr, "name" => name}) do
    case flatten_package_expr(expr) do
      nil -> name
      prefix -> "#{prefix}.#{name}"
    end
  end

  defp flatten_package_expr(%{"name" => name}), do: name
  defp flatten_package_expr(_), do: nil

  defp extract_package_from_source(content) do
    case Regex.run(~r/^\s*package\s+([A-Za-z0-9_$.]+)\s*;/m, content) do
      [_, pkg] -> pkg
      _ -> nil
    end
  end

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
