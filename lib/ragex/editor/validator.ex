defmodule Ragex.Editor.Validator do
  @moduledoc """
  Validation pipeline orchestration for code editing.

  Coordinates validation across different language-specific validators.
  Automatically selects the appropriate validator based on file extension.
  """

  alias Ragex.Editor.Types
  require Logger

  @doc """
  Callback for language-specific validators.

  Validators must implement this behavior to participate in the validation pipeline.
  """
  @callback validate(content :: String.t(), opts :: keyword()) ::
              {:ok, :valid} | {:error, [Types.validation_error()]}

  @callback can_validate?(file_path :: String.t()) :: boolean()

  @doc """
  Validates code content using the appropriate language validator.

  ## Parameters
  - `content`: Code content to validate
  - `opts`: Options
    - `:path` - File path (used for language detection)
    - `:language` - Explicit language override
    - `:validator` - Explicit validator module override

  ## Returns
  - `{:ok, :valid}` if code is valid
  - `{:error, errors}` if validation fails
  - `{:ok, :no_validator}` if no validator available for language

  ## Examples

      iex> Validator.validate("defmodule Test do\\nend", path: "test.ex")
      {:ok, :valid}
      
      iex> Validator.validate("defmodule Test", path: "test.ex")  
      {:error, [%{message: "unexpected end of file", ...}]}
  """
  @spec validate(String.t(), keyword()) ::
          {:ok, :valid | :no_validator} | {:error, [Types.validation_error()]}
  def validate(content, opts \\ []) do
    with {:ok, validator} <- select_validator(opts) do
      Logger.debug("Validating with #{inspect(validator)}")
      validator.validate(content, opts)
    else
      {:error, :no_validator} ->
        Logger.debug("No validator available for #{inspect(opts[:path])}")
        {:ok, :no_validator}
    end
  end

  @doc """
  Checks if validation is available for a given file or language.

  ## Examples

      iex> Validator.can_validate?(path: "test.ex")
      true
      
      iex> Validator.can_validate?(path: "test.unknown")
      false
  """
  @spec can_validate?(keyword()) :: boolean()
  def can_validate?(opts) do
    case select_validator(opts) do
      {:ok, _validator} -> true
      {:error, :no_validator} -> false
    end
  end

  @doc """
  Lists all available validators.

  Returns a map of language to validator module.
  """
  @spec list_validators() :: %{atom() => module()}
  def list_validators do
    %{
      elixir: Ragex.Editor.Validators.Elixir,
      erlang: Ragex.Editor.Validators.Erlang,
      python: Ragex.Editor.Validators.Python,
      javascript: Ragex.Editor.Validators.Javascript
    }
  end

  @doc """
  Gets the validator module for a specific language.
  """
  @spec get_validator(atom()) :: {:ok, module()} | {:error, :no_validator}
  def get_validator(language) when is_atom(language) do
    case Map.get(list_validators(), language) do
      nil -> {:error, :no_validator}
      validator -> {:ok, validator}
    end
  end

  # Private functions

  defp select_validator(opts) do
    cond do
      # Explicit validator module provided
      validator = Keyword.get(opts, :validator) ->
        if validator_module?(validator) do
          {:ok, validator}
        else
          {:error, :no_validator}
        end

      # Explicit language provided
      language = Keyword.get(opts, :language) ->
        get_validator(language)

      # Detect from file path
      path = Keyword.get(opts, :path) ->
        detect_validator_from_path(path)

      # No way to determine validator
      true ->
        {:error, :no_validator}
    end
  end

  defp detect_validator_from_path(path) do
    ext = Path.extname(path)

    language =
      case ext do
        ".ex" -> :elixir
        ".exs" -> :elixir
        ".erl" -> :erlang
        ".hrl" -> :erlang
        ".py" -> :python
        ".js" -> :javascript
        ".jsx" -> :javascript
        # TypeScript uses JS validator
        ".ts" -> :javascript
        ".tsx" -> :javascript
        ".mjs" -> :javascript
        ".cjs" -> :javascript
        _ -> nil
      end

    if language do
      get_validator(language)
    else
      {:error, :no_validator}
    end
  end

  defp validator_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :validate, 2) and
      function_exported?(module, :can_validate?, 1)
  end

  defp validator_module?(_), do: false
end
