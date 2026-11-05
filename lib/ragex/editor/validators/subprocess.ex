defmodule Ragex.Editor.Validators.Subprocess do
  @moduledoc """
  Generic syntax validator that shells out to an external toolchain.

  Many languages are validated the same way: write the source to a temporary
  file, run the language's own parser/compiler over it, and interpret the
  tool's output. Historically each of those languages had its own near-identical
  validator module (`Python`, `Ruby`, `Javascript`) differing only in *data*:
  which binary to run, which arguments, and how to parse the error line.

  This module captures that shared shape once. A language supplies a
  `spec` (see `t:spec/0`) describing the differences; everything else -- temp
  file handling, missing-binary detection, error construction -- is shared.

  ## Spec

  A spec is a keyword list with:

    * `:extension` -- temp-file extension, e.g. `".py"` (required)
    * `:command` -- `fn path, content -> {bin, args, opts} end` returning the
      command to run. `opts` are passed straight to `System.cmd/3`
      (e.g. `env:`, `stderr_to_stdout:`). Required.
    * `:bin` -- the executable name used to detect a missing toolchain and to
      build the "not found" message. Required.
    * `:missing_message` -- message shown when `:bin` is not on the PATH.
    * `:parse` -- `fn output, exit_code -> result end` that turns the tool's
      output into `{:ok, :valid}` or `{:error, [validation_error]}`. Defaults to
      the shared `SYNTAX_ERROR:line:col:message` parser.

  ## Examples

      defmodule MyLang do
        @behaviour Ragex.Editor.Validator

        @impl true
        def validate(content, _opts \\\\ []) do
          Ragex.Editor.Validators.Subprocess.validate(content, spec())
        end

        @impl true
        def can_validate?(path), do: Path.extname(path) == ".mylang"

        defp spec do
          [
            extension: ".mylang",
            bin: "mylang",
            missing_message: "mylang not found",
            command: fn path, _content -> {"mylang", ["--check", path], stderr_to_stdout: true} end
          ]
        end
      end
  """

  alias Ragex.Editor.Types
  alias Ragex.LanguageSupport

  @type validation_result :: {:ok, :valid} | {:error, [Types.validation_error()]}

  @type spec :: [
          extension: String.t(),
          command: (String.t(), String.t() -> {String.t(), [String.t()], keyword()}),
          bin: String.t(),
          missing_message: String.t(),
          parse: (String.t(), integer() -> validation_result())
        ]

  @doc """
  Validates `content` using the external toolchain described by `spec`.

  Returns `{:ok, :valid}` on success, or `{:error, [error]}` where `error`
  carries the line/column and message reported by the tool.
  """
  @spec validate(String.t(), spec()) :: validation_result()
  def validate(content, spec) when is_binary(content) and is_list(spec) do
    ext = Keyword.fetch!(spec, :extension)

    case write_temp_file(content, ext) do
      {:ok, temp_path} ->
        try do
          run_validation(temp_path, content, spec)
        after
          File.rm(temp_path)
        end

      {:error, reason} ->
        message = if is_binary(reason), do: reason, else: "Failed to validate: #{inspect(reason)}"
        {:error, [Types.validation_error(message, severity: :error)]}
    end
  end

  # Private

  defp write_temp_file(content, ext) do
    temp_path =
      Path.join(
        System.tmp_dir!(),
        "ragex_validate_#{:rand.uniform(999_999)}#{ext}"
      )

    case File.write(temp_path, content) do
      :ok -> {:ok, temp_path}
      error -> error
    end
  end

  defp run_validation(temp_path, content, spec) do
    {bin, args, cmd_opts} = Keyword.fetch!(spec, :command).(temp_path, content)
    bin = LanguageSupport.find_executable(bin) || bin

    # Always inject the augmented PATH/NODE_PATH and capture stderr; the spec
    # may add further options but cannot override these two.
    cmd_opts =
      cmd_opts
      |> Keyword.drop([:env, :stderr_to_stdout])
      |> Keyword.merge(env: LanguageSupport.subprocess_env(), stderr_to_stdout: true)

    case System.cmd(bin, args, cmd_opts) do
      {_output, 0} ->
        {:ok, :valid}

      {output, exit_code} ->
        parse_fn = Keyword.get(spec, :parse, &parse_syntax_error/2)
        parse_fn.(output, exit_code)
    end
  rescue
    e in ErlangError ->
      if e.original == :enoent do
        message = Keyword.get(spec, :missing_message, "#{Keyword.fetch!(spec, :bin)} not found")
        {:error, [Types.validation_error(message, severity: :warning)]}
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  Default parser for tools that print `SYNTAX_ERROR:line:column:message`.

  Also accepts a bare `ERROR:message` line and falls back to reporting the raw
  output.
  """
  @spec parse_syntax_error(String.t(), integer()) :: validation_result()
  def parse_syntax_error(output, _exit_code) do
    case String.split(String.trim(output), ":", parts: 4) do
      ["SYNTAX_ERROR", line_str, col_str, message] ->
        {:error,
         [
           Types.validation_error(message,
             line: parse_int(line_str),
             column: parse_int(col_str),
             severity: :error
           )
         ]}

      ["ERROR", message] ->
        {:error, [Types.validation_error(message, severity: :error)]}

      _ ->
        {:error, [Types.validation_error("Unknown error: #{output}", severity: :error)]}
    end
  end

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> nil
    end
  end
end
