defmodule Ragex.Analyzers.Behaviour do
  @moduledoc """
  Defines the behaviour for language-specific code analyzers.

  Each analyzer must implement these callbacks to extract code structure
  and metadata from source files in their respective languages.
  """

  @type analysis_result :: %{
          modules: [module_info()],
          functions: [function_info()],
          calls: [call_info()],
          imports: [import_info()]
        }

  @type module_info :: %{
          name: String.t() | atom(),
          file: String.t(),
          line: integer(),
          doc: String.t() | nil,
          metadata: map()
        }

  @type function_info :: %{
          name: atom(),
          arity: integer(),
          module: String.t() | atom(),
          file: String.t(),
          line: integer(),
          doc: String.t() | nil,
          visibility: :public | :private,
          metadata: map()
        }

  @type call_info :: %{
          from_module: String.t() | atom(),
          from_function: atom(),
          from_arity: integer(),
          to_module: String.t() | atom(),
          to_function: atom(),
          to_arity: integer(),
          line: integer()
        }

  @type import_info :: %{
          from_module: String.t() | atom(),
          to_module: String.t() | atom(),
          type: :import | :require | :use | :alias
        }

  @doc """
  Analyzes source code and extracts structure information.

  Returns an analysis result containing modules, functions, calls, and imports.
  """
  @callback analyze(source :: String.t(), file_path :: String.t()) ::
              {:ok, analysis_result()} | {:error, term()}

  @doc """
  Returns the file extensions supported by this analyzer.
  """
  @callback supported_extensions() :: [String.t()]
end
