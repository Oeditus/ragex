defmodule Ragex.Language do
  @moduledoc """
  Ragex's view of a supported language.

  This is a superset of `Metastatic.Language`: it carries everything Metastatic
  knows (adapter module, extensions, experimental/documentation flags) plus the
  Ragex-only concerns that used to be hardcoded across four separate modules:

    * `:validator` -- the `Ragex.Editor.Validator` implementation (or `nil`)
    * `:native_analyzer` -- the fallback `Ragex.Analyzers.Behaviour` module
      used when Metastatic parsing fails (or `nil`)
    * `:scip_indexer` -- SCIP indexer metadata for languages Ragex cannot parse
      natively (or `nil`)

  Instances are built by `Ragex.Languages` from `Metastatic.Languages` plus a
  small Ragex-local overlay, so adding a language to Metastatic automatically
  makes it visible to Ragex; only the extra concerns need to be supplied here.
  """

  @enforce_keys [:language]
  defstruct [
    :language,
    :adapter,
    :validator,
    :native_analyzer,
    :scip_indexer,
    extensions: [],
    experimental?: false,
    documentation?: false
  ]

  @type scip_indexer :: %{
          indexer: String.t(),
          indexer_args: [String.t()],
          marker_files: [String.t()]
        }

  @type t :: %__MODULE__{
          language: atom(),
          adapter: module() | nil,
          validator: module() | nil,
          native_analyzer: module() | nil,
          scip_indexer: scip_indexer() | nil,
          extensions: [String.t()],
          experimental?: boolean(),
          documentation?: boolean()
        }

  @doc """
  Builds a Ragex language descriptor.

  Accepts the fields of a `Metastatic.Language` plus the Ragex-only concerns.

  ## Examples

      iex> lang = Ragex.Language.new(:elixir, adapter: Metastatic.Adapters.Elixir,
      ...>   validator: Ragex.Editor.Validators.Elixir, native_analyzer: Ragex.Analyzers.Elixir)
      iex> lang.language
      :elixir
      iex> lang.adapter
      Metastatic.Adapters.Elixir
  """
  @spec new(atom(), keyword()) :: t()
  def new(language, opts \\ []) when is_atom(language) do
    %__MODULE__{
      language: language,
      adapter: Keyword.get(opts, :adapter),
      validator: Keyword.get(opts, :validator),
      native_analyzer: Keyword.get(opts, :native_analyzer),
      scip_indexer: Keyword.get(opts, :scip_indexer),
      extensions: Keyword.get(opts, :extensions, []),
      experimental?: Keyword.get(opts, :experimental?, false),
      documentation?: Keyword.get(opts, :documentation?, false)
    }
  end
end
