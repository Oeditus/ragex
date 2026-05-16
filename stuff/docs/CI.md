# CI / Diff-Based Analysis

Guide to using Ragex and MetaCredo for incremental, diff-based code analysis
in CI/CD pipelines. Only files changed in a pull request are analyzed,
giving fast feedback without noise from pre-existing issues.

## Table of Contents

1. [Quick Start](#quick-start)
2. [How It Works](#how-it-works)
3. [mix ragex.analyze --diff](#mix-ragexanalyze---diff)
4. [mix ragex.ci](#mix-ragexci)
5. [Output Formats](#output-formats)
6. [GitHub Actions Integration](#github-actions-integration)
7. [Other CI Systems](#other-ci-systems)
8. [API Reference](#api-reference)
9. [Configuration](#configuration)
10. [Troubleshooting](#troubleshooting)

## Quick Start

Add one line to your CI pipeline:

```bash
mix ragex.ci --format github
```

This runs both **Ragex analysis** (security, complexity, dead code, etc.)
and **MetaCredo checks** (72 cross-language static analysis checks) on the
files changed in the current branch vs `origin/main`. Issues appear as
inline PR annotations in GitHub.

## How It Works

```
git diff origin/main...HEAD
        |
        v
  [changed files list]  --- filter by supported extensions
        |
        v
  [Ragex: index only those files into knowledge graph]
        |
        v
  [Run all enabled analyses on the full graph]
        |
        v
  [Filter results to only report issues in changed files]
        |
        v
  [MetaCredo: run 72 checks on changed files only]
        |
        v
  [Output in CI / GitHub / JSON format]
        |
        v
  [Exit non-zero if issues found]
```

Key design decisions:

- **Indexing is scoped**: only changed files are parsed and added to the
  knowledge graph, which is the main performance win (seconds instead of
  minutes for large projects).
- **Whole-project analyses still work**: dead code detection, circular
  dependencies, coupling metrics, etc. run on the full graph but only
  *report* issues that touch changed files. This means a PR that
  introduces a new circular dependency will still be flagged.
- **Deleted files are excluded**: the diff filter (`ACMR`) only includes
  Added, Copied, Modified, and Renamed files.

## mix ragex.analyze --diff

The `--diff` flag enables diff-based mode on the existing `mix ragex.analyze`
task. It implies `--ci` (machine-friendly output, non-zero exit on issues).

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--diff` | `false` | Enable diff-based analysis |
| `--base REF` | `origin/main` | Base git ref (the target branch) |
| `--head REF` | `HEAD` | Head git ref (the PR branch) |
| `--format FORMAT` | `text` | Output format: `text`, `json`, `markdown`, `github` |

All other `mix ragex.analyze` flags work as usual (`--security`,
`--complexity`, `--severity`, etc.).

### Examples

```bash
# Analyze only changed files, CI text output
mix ragex.analyze --diff

# Custom base branch
mix ragex.analyze --diff --base origin/develop

# Only security checks on changed files, GitHub annotations
mix ragex.analyze --diff --security --format github

# JSON output for downstream tooling
mix ragex.analyze --diff --format json --output report.json
```

## mix ragex.ci

A convenience task that runs both tools in sequence:

1. `mix ragex.analyze --diff` (all Ragex analyses)
2. `mix metacredo --diff --strict` (all MetaCredo checks)

Exits with code 1 if either tool finds issues.

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--base REF` | `origin/main` | Base git ref |
| `--head REF` | `HEAD` | Head git ref |
| `--format FORMAT` | `text` | Output format: `text`, `github` |

### Examples

```bash
# Default: diff against origin/main
mix ragex.ci

# GitHub Actions with inline annotations
mix ragex.ci --format github

# Custom base ref (e.g. from $GITHUB_BASE_REF)
mix ragex.ci --base origin/develop
```

## Output Formats

### text (default)

Machine-readable one-line-per-issue format (no ANSI colors):

```
SECURITY: sql_injection (critical) lib/repo.ex:42 - SQL concatenation with user input
COMPLEXITY: MyApp.Worker.process/3 (cyclomatic=18)
ragex: 2 issue(s) found
```

### github

GitHub Actions workflow commands that produce inline PR annotations:

```
::error file=lib/repo.ex,line=42::SECURITY sql_injection: SQL concatenation with user input
::warning file=lib/worker.ex,line=15::COMPLEXITY MyApp.Worker.process/3 cyclomatic=18
ragex: 2 issue(s) found
```

GitHub renders these as annotations directly on the PR diff:

- `::error` -- red annotation, blocks merge with branch protection
- `::warning` -- yellow annotation, informational
- `::notice` -- grey annotation, low priority

### json

Full structured report for downstream processing:

```bash
mix ragex.analyze --diff --format json --output report.json
```

### markdown

Human-readable report with headers and formatting:

```bash
mix ragex.analyze --diff --format markdown --output report.md
```

## GitHub Actions Integration

### Recommended workflow

Add this to `.github/workflows/ci.yml`:

```yaml
analysis:
  name: Diff Analysis
  if: github.event_name == 'pull_request'
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0  # Required for git diff to work

    - uses: erlef/setup-beam@v1
      with:
        elixir-version: '1.19'
        otp-version: '28'

    - name: Restore dependencies cache
      uses: actions/cache@v4
      with:
        path: |
          deps
          _build
        key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}

    - name: Install dependencies
      run: mix deps.get

    - name: Run diff analysis
      run: mix ragex.ci --base origin/${{ github.base_ref }} --format github
```

Important notes:

- **`fetch-depth: 0`** is required so `git diff` can access the full
  history. Without it, GitHub Actions performs a shallow clone and the
  diff will fail.
- **`origin/${{ github.base_ref }}`** resolves to the PR's target branch
  (e.g. `origin/main`). This is the correct base ref for PR analysis.

### Separate jobs for ragex and metacredo

If you prefer separate CI jobs (e.g. for independent failure reporting):

```yaml
ragex-analysis:
  name: Ragex Analysis
  if: github.event_name == 'pull_request'
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0
    - uses: erlef/setup-beam@v1
      with:
        elixir-version: '1.19'
        otp-version: '28'
    - run: mix deps.get
    - run: mix ragex.analyze --diff --base origin/${{ github.base_ref }} --format github

metacredo-analysis:
  name: MetaCredo Analysis
  if: github.event_name == 'pull_request'
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0
    - uses: erlef/setup-beam@v1
      with:
        elixir-version: '1.19'
        otp-version: '28'
    - run: mix deps.get
    - run: mix metacredo --diff --base origin/${{ github.base_ref }} --format github --strict
```

## Other CI Systems

### GitLab CI

```yaml
ragex-analysis:
  stage: test
  only:
    - merge_requests
  script:
    - mix deps.get
    - mix ragex.ci --base origin/$CI_MERGE_REQUEST_TARGET_BRANCH_NAME
```

### Generic (any CI)

```bash
#!/bin/bash
# ci-analysis.sh
set -e

BASE_REF="${CI_BASE_REF:-origin/main}"

# Run analysis, exit non-zero on issues
mix ragex.analyze --diff --base "$BASE_REF" --ci
mix metacredo --diff --base "$BASE_REF" --strict
```

### Pre-commit hook

```bash
#!/bin/bash
# .git/hooks/pre-commit

# Analyze staged files against HEAD
STAGED=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(ex|exs|py|rb|erl)$')

if [ -n "$STAGED" ]; then
  echo "Running analysis on staged files..."
  mix ragex.analyze --diff --base HEAD~1 --head HEAD --ci
fi
```

## API Reference

### Ragex.Git.Diff

The diff file resolver module. Tries `egit` (libgit2 NIF) first, falls
back to the `git` CLI.

```elixir
# Get changed files between two refs
{:ok, files} = Ragex.Git.Diff.changed_files("/path/to/repo",
  base: "origin/main",
  head: "HEAD",
  filter: "ACMR",
  extensions: [".ex", ".exs"]
)
# => {:ok, ["lib/foo.ex", "lib/bar.ex"]}

# Convenience: resolve repo root + changed files
{:ok, repo_root, files} = Ragex.Git.Diff.changed_files_for_path(".")

# Bang version (raises on error)
files = Ragex.Git.Diff.changed_files!("/path/to/repo")
```

### Ragex.Analysis.Runner

```elixir
# Analyze only specific files (used by diff mode)
{:ok, result} = Runner.analyze_files(["/abs/path/lib/foo.ex", "/abs/path/lib/bar.ex"])

# Filter analysis results to changed files
changed_set = MapSet.new(["lib/foo.ex", "lib/bar.ex"])
filtered = Runner.filter_results_by_files(results, changed_set)
```

The filter preserves structural analyses (circulars, coupling, god modules)
unmodified, since they describe project-wide properties. Per-file analyses
(security, complexity, smells, duplicates, dead code) are filtered to only
include issues in the changed file set.

### MetaCredo.Git

Standalone git helper (no ragex dependency):

```elixir
# Resolve repo root
repo = MetaCredo.Git.repo_root(File.cwd!())

# Get changed files
{:ok, files} = MetaCredo.Git.changed_files(repo,
  base: "origin/main",
  head: "HEAD",
  extensions: [".ex", ".exs"]
)
```

## Configuration

### Base ref

The default base ref is `origin/main`. Override it for projects that use
a different default branch:

```bash
# develop-based workflow
mix ragex.ci --base origin/develop

# Release branch
mix ragex.ci --base origin/release/v2
```

### Selecting analyses

In diff mode, all analyses are enabled by default. To run only specific
checks:

```bash
# Only security + circular dependency detection
mix ragex.analyze --diff --security --circulars --format github
```

### Severity filtering

```bash
# Only critical and high severity issues (skip medium/low)
mix ragex.analyze --diff --severity high --format github
```

## Troubleshooting

### "fatal: bad revision 'origin/main...HEAD'"

**Cause**: the remote `origin/main` branch is not available in the CI
checkout.

**Fix**: ensure `fetch-depth: 0` in `actions/checkout@v4`, or explicitly
fetch the base branch:

```bash
git fetch origin main
mix ragex.ci --base origin/main
```

### "No changed files found in diff, nothing to analyze"

**Cause**: the diff between base and head produced no files matching
supported extensions.

This is expected when only non-code files changed (e.g. README, images).
The task exits cleanly with code 0.

### "--diff requires a git repository, but none was found"

**Cause**: running outside a git repository.

**Fix**: ensure the working directory is inside a git repo. In CI, the
checkout step typically handles this.

### Slow on first run

The first `mix ragex.ci` invocation in CI compiles the project and its
dependencies (including EXLA for ML). Subsequent runs use the cache.

Tips for faster CI:
- Cache `deps/` and `_build/` between runs
- Use `actions/cache@v4` keyed on `mix.lock`
- Consider a separate `deps` job that other jobs depend on

---

**Version:** Ragex 0.16.0
**Last Updated:** May 2026
