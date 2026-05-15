# Git Archaeology

Ragex's git integration connects repository history to the knowledge graph,
enabling questions like "who wrote this?", "when was this last touched?",
"what changes when this changes?", and "what did reviewers say?"

## Architecture

```
                     +──────────────+
                     |  MCP Tools   |   git_blame, git_history, git_pr_info,
                     |  (GitTools)  |   co_change_analysis, git_enrich
                     +──────┬───────+
                            |
              +─────────────┼─────────────+
              |             |             |
        +─────┴─────+ +────┴────+ +──────┴──────+
        |   Blame   | |   Log   | |  CoChange   |
        | (high-lvl)| |(high-lvl)| | (ETS-based) |
        +─────┬─────+ +────┬────+ +──────┬──────+
              |             |             |
              +─────────────┼─────────────+
                            |
                    +───────┴────────+
                    |    Backend     |  behaviour
                    | active() ->   |
                    +───┬───────┬───+
                        |       |
                  +─────┴──+ +──┴──────+
                  |  Egit  | |   CLI   |
                  |  (NIF) | |(System  |
                  |        | |  .cmd)  |
                  +────────+ +─────────+
```

## Backend Strategy

Two backends implement the `Ragex.Git.Backend` behaviour:

**Egit (NIF, optional)**
- Uses `{:egit, "~> 0.2"}` -- Erlang NIF bindings to libgit2
- Returns structured maps directly, no text parsing
- NIF reference isolated in `Ragex.Git.RepoServer` GenServer
- If the NIF crashes, only the GenServer dies; supervisor restarts it
- Requires `libgit2-dev` at build time

**CLI (universal fallback)**
- Shells out to `git` via `System.cmd/3`
- Parses porcelain/machine-readable output
- Works everywhere git is installed
- Only path for `git log -L` (function evolution) -- libgit2 doesn't support it

Auto-detection: if `:git` module (egit) is loaded, use it. Otherwise CLI.
Override: `config :ragex, git_backend: :egit | :cli | :auto`

## MCP Tools

### git_blame

Line-by-line authorship for a file or range.

```json
{
  "name": "git_blame",
  "arguments": {
    "path": "lib/my_module.ex",
    "start_line": 10,
    "end_line": 20,
    "enrich_pr": true
  }
}
```

Returns per-line entries with SHA, author, date, summary, content.
When `enrich_pr: true`, attaches PR number and title (requires PR indexing).

### git_history

File or function history with filtering.

```json
{
  "name": "git_history",
  "arguments": {
    "path": "lib/accounts.ex",
    "function_name": "create_user",
    "max_results": 10,
    "author": "alice"
  }
}
```

When `function_name` is provided, uses `git log -L` for precise function tracking.

### git_pr_info

PR details and review comments.

```json
{
  "name": "git_pr_info",
  "arguments": {
    "pr_number": 42
  }
}
```

Or find review comments for a file:

```json
{
  "name": "git_pr_info",
  "arguments": {
    "path": "lib/user.ex"
  }
}
```

Requires `gh` (GitHub) or `glab` (GitLab) CLI and prior PR indexing.

### co_change_analysis

Discover files that frequently change together.

```json
{
  "name": "co_change_analysis",
  "arguments": {
    "path": "lib/accounts.ex",
    "analyze_first": true,
    "max_commits": 500
  }
}
```

Returns co-change partners sorted by frequency. Useful for predicting
blast radius of changes and understanding hidden coupling.

### git_enrich

Enrich the knowledge graph with git metadata.

```json
{
  "name": "git_enrich",
  "arguments": {
    "path": "/opt/project",
    "analyze_cochange": true
  }
}
```

Adds to graph nodes: `last_author`, `last_modified`, `git_age_days`.
Adds edges: `:authored_by`, `:co_changes_with`.

## Knowledge Graph Integration

After enrichment, the graph contains three new edge types:

- `:authored_by` -- file/module node -> author identifier
- `:introduced_in_pr` -- file node -> PR number
- `:co_changes_with` -- file node -> file node (weighted by co-change count)

Module nodes gain metadata:
- `:last_author` -- who last modified the file
- `:git_age_days` -- days since last modification

## PR Attribution

Uses `gh` (GitHub) or `glab` (GitLab) CLI for PR data:

- PR number, title, author, description
- Merge commit SHA
- Files changed
- Review comments (with file:line locations)

PR index persisted to `~/.ragex/pr_index/<hash>.etf` (Erlang term format).
Incremental: only fetches PRs newer than last indexed.

## Co-Change Analysis

Algorithm:
1. Walk the last N commits (default 500)
2. For each commit, get the list of changed files
3. For every pair of files in the same commit, increment a counter
4. Skip commits touching >50 files (merges, bulk changes)
5. Store in ETS table `:ragex_cochange`

Persisted to `~/.ragex/cochange/<hash>.etf`.

## Configuration

```elixir
config :ragex,
  # Backend selection: :auto (default), :egit, or :cli
  git_backend: :auto
```

## Dependencies

- `git` CLI (required for CLI backend and function evolution)
- `gh` or `glab` CLI (optional, for PR attribution)
- `{:egit, "~> 0.2"}` (optional, for NIF backend)
- `libgit2-dev` (optional, build-time only, for egit)

All git features degrade gracefully when dependencies are unavailable.
