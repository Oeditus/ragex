# SCIP Bridge

The SCIP Bridge enables Ragex to analyze codebases in 10+ additional languages
(Go, Rust, Java, Kotlin, Scala, C/C++, C#, Ruby, Dart, PHP) by ingesting
SCIP (Source Code Intelligence Protocol) index files into the knowledge graph.

## Zero Dependencies

The bridge adds **no new Elixir dependencies**. It works by:

1. Running external SCIP indexer binaries (e.g. `scip-go`, `rust-analyzer`)
2. Converting the binary SCIP output to JSON via the `scip` CLI
3. Parsing the JSON with OTP's `:json.decode/1`
4. Mapping SCIP symbols/occurrences to Ragex's knowledge graph

## Supported Languages

| Language | Indexer         | Marker File(s)                | Extensions           |
|----------|-----------------|-------------------------------|----------------------|
| Go       | `scip-go`       | `go.mod`                      | `.go`                |
| Rust     | `rust-analyzer` | `Cargo.toml`                  | `.rs`                |
| Java     | `scip-java`     | `pom.xml`, `build.gradle`     | `.java`              |
| Kotlin   | `scip-java`     | `build.gradle.kts`            | `.kt`, `.kts`        |
| Scala    | `scip-java`     | `build.sbt`                   | `.scala`             |
| C/C++    | `scip-clang`    | `CMakeLists.txt`              | `.c`, `.cpp`, `.h`   |
| C#       | `scip-dotnet`   | `*.csproj`, `*.sln`           | `.cs`                |
| Ruby     | `scip-ruby`     | `Gemfile`                     | `.rb`                |
| Dart     | `scip-dart`     | `pubspec.yaml`                | `.dart`              |
| PHP      | `scip-php`      | `composer.json`               | `.php`               |

## MCP Tools

### scip_status

Check what SCIP indexers are available and which languages are detected.

```json
{"name": "scip_status", "arguments": {"path": "/opt/my_project"}}
```

### scip_index

Run a SCIP indexer and ingest results into the knowledge graph.

```json
{"name": "scip_index", "arguments": {"path": "/opt/my_project", "language": "go"}}
```

After indexing, all existing tools work with SCIP data: `query_graph`,
`semantic_search`, `find_callers`, `analyze_impact`, etc.

## Architecture

```
  User Project (Go/Rust/Java/...)
        |
        v
  SCIP Indexer (scip-go, rust-analyzer, scip-java, ...)
        |
        v
  index.scip (protobuf binary)
        |
        v
  scip CLI (`scip print --json`)
        |
        v
  JSON string
        |
        v
  Parser (Ragex.Analyzers.SCIP.Parser)
        |
        v
  %{modules, functions, calls, imports}
        |
        v
  Adapter (Ragex.Analyzers.SCIP.Adapter)
        |
        v
  Knowledge Graph (Store.add_node, Store.add_edge)
```

## Relationship to Native Analyzers

SCIP is **complementary** to Ragex's native analyzers:

- **Elixir/Erlang/Python/JS/Ruby** -- use native parsers or Metastatic
  (deeper AST access, refactoring support)
- **Go/Rust/Java/Kotlin/Scala/C++/C#/Dart/PHP** -- use SCIP bridge
  (read-only analysis, call graph, search)

## Prerequisites

1. Install the `scip` CLI: download from https://github.com/scip-code/scip/releases
2. Install language-specific indexers (e.g. `go install github.com/sourcegraph/scip-go@latest`)
3. Run `scip_status` to verify availability
