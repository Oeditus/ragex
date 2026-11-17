defmodule Ragex.Plugin.LanguageRunner do
  @moduledoc """
  Dispatches language-specific post-processing to registered language plugins.

  A `Ragex.Plugin.Language` may implement `c:Ragex.Plugin.Language.post_process/2`
  to repair or enrich a parsed document before any analyzer sees it. This module
  is the single place that calls those hooks.

  ## Failure isolation

  Post-processing runs on the indexing hot path, so a plugin that raises or
  returns an error must never abort the parse. Failures are logged and the
  document is passed through unchanged: an unrepairred document is a degraded
  result, whereas a raised exception is a lost file.

  ## Ordering

  Plugins run in registry priority order (lowest first), so a repair plugin can
  be given a lower priority than an enrichment plugin that depends on it.
  """

  require Logger

  alias Metastatic.Document
  alias Ragex.Plugin.Registry

  @doc """
  Runs every language plugin's `post_process/2` for `language`.

  Returns the (possibly rewritten) document. Never returns an error: a plugin
  failure is logged and skipped.
  """
  @spec post_process(Document.t(), atom(), keyword()) :: Document.t()
  def post_process(doc, language, opts \\ [])

  def post_process(%Document{} = doc, language, opts) when is_atom(language) do
    language
    |> plugins_for()
    |> Enum.reduce(doc, &apply_plugin(&1, &2, opts))
  end

  def post_process(doc, _language, _opts), do: doc

  @doc """
  Returns the language plugins serving `language`, in priority order.

  Returns `[]` when the registry is not running (e.g. in a bare test setup).
  """
  @spec plugins_for(atom()) :: [module()]
  def plugins_for(language) when is_atom(language) do
    if Process.whereis(Registry) do
      Registry.plugins_for_language(language)
    else
      []
    end
  catch
    _, _ -> []
  end

  defp apply_plugin(mod, doc, opts) do
    if function_exported?(mod, :post_process, 2) do
      case mod.post_process(doc, opts) do
        {:ok, %Document{} = updated} ->
          updated

        {:error, reason} ->
          Logger.warning(
            "Language plugin #{inspect(mod)} failed post_process: #{inspect(reason)}"
          )

          doc

        other ->
          Logger.warning(
            "Language plugin #{inspect(mod)} returned an unexpected value from " <>
              "post_process/2: #{inspect(other)}"
          )

          doc
      end
    else
      doc
    end
  rescue
    e ->
      Logger.warning(
        "Language plugin #{inspect(mod)} raised in post_process/2: #{Exception.message(e)}"
      )

      doc
  end
end
