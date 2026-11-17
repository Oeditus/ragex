# Language-Dependent Plugins

Ragex plugins come in two flavours.

**Generic plugins** (`:graph_analytics`, `:git_archaeology`, `:code_quality`,
`:security_audit`, `:url_analyzer`) are language-agnostic. Their tools are
advertised for every project, whatever it is written in.

**Language plugins** are scoped to one or more source languages. Their tools are
only advertised when the workspace actually contains those languages, and they
can additionally contribute behaviour that is not an MCP tool at all — AST
repairs, purity rules, idiom detectors.

This document describes the second kind.

---

## The behaviour

`Ragex.Plugin.Language` is a *refinement* of `Ragex.Plugin`, not a replacement.
A language plugin still implements `info/0`, `tools/0` and `execute/2`, and is
registered through the same `Ragex.Plugin.Registry`. The extra callbacks are
optional hooks:

| Callback | Purpose |
|---|---|
| `languages/0` | The languages this plugin serves. Must be known to `Ragex.Languages`. |
| `available?/1` | Cheap probe for whether the backing tool is usable for a path. |
| `language_tools/1` | Tool schemas to advertise for a given language. |
| `post_process/2` | Repair or enrich a parsed document before any analyzer sees it. |

Declare the scope by adding a `:language` key to `info/0`:

```elixir
def info do
  %{
    id: :elixir_language,
    name: "Elixir Language Support",
    version: "0.1.0",
    description: "Elixir-specific analysis.",
    category: :analyzer,
    language: :elixir,
    priority: 40
  }
end
```

`:language` may be a single atom or a list.

---

## Scoping semantics

Scope governs **discovery**, never **reachability**.

- `Registry.set_active_languages/1` records which languages the workspace
  contains. `analyze_directory` derives this automatically from the files it
  finds.
- `Registry.list_tools/0` filters out language plugins whose languages are all
  inactive.
- `Registry.dispatch_tool/2` is **unaffected**. A tool that was advertised
  stays callable by name even if the active set changes underneath it. This
  mirrors the existing rule that a tool must never be advertised without a
  dispatch clause; the converse (callable but unadvertised) is safe.
- An empty active set means **scoping is disabled**: every plugin advertises
  everything. This is the default, so existing installations are unaffected.

Generic plugins declare `languages: []` and are never filtered.

---

## Post-processing pipeline

```
file → Ragex.Languages.detect_language/1
     → Ragex.LanguageSupport.parse_document/3   (Metastatic adapter)
     → Ragex.Plugin.LanguageRunner.post_process/3
     → analyzers / graph / semantic enrichment
```

`LanguageRunner` asks the registry for the plugins serving a language, calls
each `post_process/2` in priority order, and threads the document through.

No plugin currently implements `post_process/2` — the Elixir plugin's repairs
moved upstream into Metastatic — so today the runner is an identity function.
It is kept as the extension point for future language plugins that genuinely
need to rewrite a document (a Python plugin normalising decorators, say), and
it is covered by tests so that path stays working.

**Failure isolation.** Post-processing runs on the indexing hot path, so the
runner never returns an error. A plugin that raises or returns `{:error, _}` is
logged and skipped: an unrepaired document is a degraded result, whereas a
raised exception is a lost file.

---

## The Elixir plugin

`Ragex.Plugins.Languages.Elixir` is the reference implementation.

### `propwise_analyze`

Bridges [PropWise](https://hexdocs.pm/propwise), which finds functions worth
property-based testing: purity, detected patterns, inferred algebraic laws,
inverse pairs (`encode`/`decode`), and ready-to-paste StreamData/PropEr
properties.

PropWise is **not** a Ragex dependency. `available?/1` probes for it and `run/1`
degrades to an actionable error naming the exact `mix.exs` line to add. The tool
is still advertised — a user who has PropWise installed must be able to find it
— but the error says what is missing.

`total_functions` is passed through verbatim. A value of `0` means the parser
found no function definitions, not that the code is clean; the tool description
says so explicitly.

### No post-processing needed

This plugin implements no `post_process/2` hook. An earlier revision carried an
`AstFixes` shim that repaired two Elixir abstraction defects before analyzers
saw the document:

1. **Attribute setter values were never transformed.** `ToMeta`'s
   `:__attr_marker__` handler called the public `transform/1` and
   pattern-matched its `{:ok, ast, ctx}` result as a local helper, leaving every
   non-type-annotation attribute value as raw Elixir AST.

2. **`@moduledoc` and friends could surface as function calls.** When the
   attribute handler failed, `@moduledoc`, `@doc`, `@typedoc`, `@enforce_keys`,
   `@behaviour` and `@impl` fell through to the generic local-call clause and
   became `{:function_call, [name: "moduledoc"], [...]}` — fatal for consumers
   that walk `:function_call` nodes.

Both are fixed in Metastatic itself (0.37.2+), so the shim was deleted.
`test/ragex/plugins/languages/elixir_test.exs` still asserts the corrected
shapes: if Metastatic regresses, those tests fail here rather than silently
degrading every Elixir analysis.
---

## Adding a language plugin

1. Implement `Ragex.Plugin` and `Ragex.Plugin.Language`.
2. Add `language: :your_language` to `info/0`.
3. Register it in `Ragex.Plugin.Registry.@default_plugins` or via
   `config :ragex, :plugins`.
4. Test the three scoping cases: language active, language inactive, scoping
   disabled.

See `test/ragex/plugins/languages/elixir_test.exs` and
`test/ragex/plugin/language_scoping_test.exs`.
