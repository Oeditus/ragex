defmodule Ragex.Editor.Validators.Rust do
  @moduledoc """
  Rust code validator.

  Uses `rustc` in parse-only mode to validate Rust syntax. `rustc` is the
  authoritative parser for the language, so this reports exactly the errors the
  compiler would, with real line/column positions.

  ## Why `rustc` and not `cargo check`

  `cargo check` needs a crate (`Cargo.toml`, a target layout, a dependency
  graph) and takes seconds. A validator runs on every keystroke-sized edit, so
  it must be a single-file, dependency-free parse. `rustc --emit=metadata` on
  the buffer alone gives that: it parses and type-checks the fragment in
  isolation and returns in milliseconds.

  ## Diagnostics

  `rustc` reports one JSON object per line with `--error-format=json`. Only
  `level: "error"` entries are surfaced — warnings are noise in an editor
  gutter, and a fragment compiled alone is *always* full of `dead_code`.

  ## Requirements

  A `rustc` on `PATH`. When it is missing, validation degrades to a warning
  rather than failing the edit.
  """

  @behaviour Ragex.Editor.Validator

  alias Ragex.Editor.Types
  alias Ragex.Editor.Validators.Subprocess

  @impl true
  def validate(content, _opts \\ []) do
    Subprocess.validate(content, spec())
  end

  @impl true
  def can_validate?(path) when is_binary(path) do
    Path.extname(path) == ".rs"
  end

  def can_validate?(_), do: false

  # Private

  defp spec do
    [
      extension: ".rs",
      bin: "rustc",
      missing_message: "rustc not found. Install a Rust toolchain to validate Rust files.",
      command: fn path, _content -> {rustc(), rustc_args(path), [stderr_to_stdout: true]} end,
      parse: &parse_diagnostics/2
    ]
  end

  defp rustc do
    System.find_executable("rustc") || "rustc"
  end

  # `--error-format=json` (not `--message-format`, which is a cargo flag).
  # `--allow=warnings` keeps the payload to errors only.
  defp rustc_args(path) do
    [
      "--edition",
      "2021",
      "--crate-type",
      "lib",
      "--emit=metadata",
      "--error-format=json",
      "--allow=warnings",
      "-o",
      Path.join(System.tmp_dir!(), "ragex_rust_check.rmeta"),
      path
    ]
  end

  @doc """
  Parses `rustc --error-format=json` output into validation errors.

  Exposed for testing: the parsing is the only non-trivial part of this
  validator, and it must not depend on a Rust toolchain to be exercised.
  """
  @spec parse_diagnostics(String.t(), integer()) :: Subprocess.validation_result()
  def parse_diagnostics(output, _exit_code) do
    errors =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&decode_line/1)
      |> Enum.filter(&(&1.level == :error))
      # `rustc` closes with a summary line ("aborting due to N previous
      # errors") that has no span. It is not a diagnostic an editor can act
      # on, and surfacing it adds a phantom error at line `nil`.
      |> Enum.reject(&summary_line?/1)

    case errors do
      [] -> {:ok, :valid}
      errors -> {:error, Enum.map(errors, &to_validation_error/1)}
    end
  end

  defp summary_line?(%{span: {nil, nil}, message: message}) do
    String.starts_with?(message, "aborting due to")
  end

  defp summary_line?(_), do: false

  defp decode_line(line) do
    case Metastatic.JSON.decode(line) do
      {:ok, %{"level" => level, "message" => message} = diagnostic} when is_binary(message) ->
        [%{level: normalise_level(level), message: message, span: primary_span(diagnostic)}]

      _ ->
        []
    end
  end

  defp normalise_level("error"), do: :error
  defp normalise_level("warning"), do: :warning
  defp normalise_level(_), do: :note

  defp primary_span(%{"spans" => spans}) when is_list(spans) do
    case Enum.find(spans, &Map.get(&1, "is_primary", false)) || List.first(spans) do
      %{"line_start" => line, "column_start" => column} -> {line, column}
      _ -> {nil, nil}
    end
  end

  defp primary_span(_), do: {nil, nil}

  defp to_validation_error(%{message: message, span: {line, column}}) do
    Types.validation_error(message, line: line, column: column, severity: :error)
  end
end
