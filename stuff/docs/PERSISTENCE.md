# Embedding Persistence

Ragex persists embedding vectors to disk to avoid regeneration across application restarts, significantly improving cold-start performance.

## Overview

The persistence layer automatically saves embeddings when the application shuts down and loads them when it starts. This eliminates the need to regenerate embeddings for unchanged code, reducing startup time from ~50s to <5s for a typical project with 1,000 entities.

### Key Features

- **Automatic**: Embeddings are saved on graceful shutdown and loaded on startup
- **Model Validation**: Ensures cached embeddings match the current embedding model
- **Project-Specific**: Each project directory has its own cache
- **Space-Efficient**: Uses ETS serialization (binary format) for compact storage
- **Compatible Models**: Can reuse embeddings from models with the same dimensions

## Cache Behavior

### Automatic Operations

The persistence layer integrates seamlessly with the Graph Store:

1. **On Startup**: Attempts to load cached embeddings
   - If cache exists and is compatible → loads instantly
   - If cache is incompatible → skips and continues
   - If no cache exists → starts fresh

2. **On Shutdown**: Saves embeddings to disk automatically
   - Only on normal/graceful shutdown (not crashes)
   - Overwrites existing cache for the project

### Cache Location

Embeddings are cached at:

```
~/.cache/ragex/<project_hash>/embeddings.ets
```

Or, if `XDG_CACHE_HOME` is set:

```
$XDG_CACHE_HOME/ragex/<project_hash>/embeddings.ets
```

The `<project_hash>` is a 16-character SHA256 hash of the project's absolute path, ensuring each project has an isolated cache.

## Model Compatibility

The persistence layer validates model compatibility before loading:

### Compatible Models

Models are compatible if they produce embeddings with the **same dimensionality**:

| Dimension | Models |
|-----------|--------|
| 384 | `all_minilm_l6_v2`, `paraphrase_multilingual` |
| 768 | `all_mpnet_base_v2`, `codebert_base` |

**Example**: If you switch from `all_minilm_l6_v2` (384 dims) to `paraphrase_multilingual` (384 dims), your cache will be automatically reused.

### Incompatible Models

If you switch to a model with **different dimensions**, the cache is invalidated and embeddings must be regenerated.

**Example**: Switching from `all_minilm_l6_v2` (384 dims) to `codebert_base` (768 dims) requires full regeneration.

The system will log:
```
[warning] Graph store initialized (cache incompatible with current model)
```

## Cache Management

### Viewing Cache Statistics

Check your cache status:

```bash
mix ragex.cache.stats
```

**Output:**
```
Ragex Embedding Cache Statistics
================================

Cache Directory: /home/user/.cache/ragex/abc123def456/
Status: Valid

Metadata:
  Model: all_minilm_l6_v2
  Dimensions: 384
  Version: 1
  Created: 2024-01-15 10:30:45
  Entity Count: 1,234

Disk Usage:
  Cache Size: 12.5 MB
  Total Ragex Caches: 3
  Total Disk Usage: 38.2 MB
```

View all caches:

```bash
mix ragex.cache.stats --all
```

### Clearing Caches

Clear the current project's cache:

```bash
mix ragex.cache.clear --current
```

Clear all Ragex caches (all projects):

```bash
mix ragex.cache.clear --all
```

Clear caches older than N days:

```bash
mix ragex.cache.clear --older-than 30
```

Skip confirmation prompt:

```bash
mix ragex.cache.clear --all --force
```

### Manual Control

The persistence layer respects graceful shutdowns. To ensure embeddings are saved:

- Use `Ctrl+C` (SIGINT) and select `a` (abort/shutdown) when prompted
- Stop the supervised application normally
- Avoid `kill -9` (SIGKILL) which prevents graceful shutdown

## Cache Metadata

Each cache file includes metadata for validation:

```elixir
%{
  version: 1,                              # Cache format version
  model_id: :all_minilm_l6_v2,            # Embedding model
  model_repo: "sentence-transformers/...", # HuggingFace repo
  dimensions: 384,                         # Vector dimensions
  timestamp: 1705315845,                   # Unix timestamp
  entity_count: 1234                       # Number of entities
}
```

This metadata ensures:
- Version compatibility (future-proofing)
- Model compatibility (dimension matching)
- Cache freshness tracking
- Quick validation without loading full cache

## Performance Impact

### Cold Start Performance

| Scenario | Time | Details |
|----------|------|---------|
| **No cache** | 50-60s | Full embedding generation for 1,000 entities |
| **Valid cache** | <5s | Load from disk + validation |
| **Incompatible cache** | 50-60s | Falls back to regeneration |

### Storage Requirements

| Entities | Dimensions | Approximate Size |
|----------|------------|------------------|
| 100 | 384 | ~1.5 MB |
| 1,000 | 384 | ~15 MB |
| 10,000 | 384 | ~150 MB |

Storage scales linearly with entity count and dimensions.

## Troubleshooting

### Cache Not Loading

**Symptom**: Startup is slow despite having used Ragex before.

**Possible Causes**:
1. Model mismatch (different dimensions)
2. Cache file corrupted
3. Changed project directory (different hash)

**Solutions**:
```bash
# Check cache status
mix ragex.cache.stats

# If incompatible, clear and let it regenerate
mix ragex.cache.clear --current
```

### Cache Size Too Large

**Symptom**: Cache directory is consuming significant disk space.

**Solution**:
```bash
# View all caches
mix ragex.cache.stats --all

# Clear old caches (e.g., older than 30 days)
mix ragex.cache.clear --older-than 30

# Or clear all to start fresh
mix ragex.cache.clear --all --force
```

### Model Changed, Cache Invalid

**Symptom**: After changing models, cache is skipped.

**Expected Behavior**: This is normal. If you switch to a model with different dimensions, the cache must be regenerated.

**Action**: No action needed. Embeddings will regenerate automatically. To switch back:

```elixir
# In config/config.exs
config :ragex, :embedding_model, :all_minilm_l6_v2
```

## Implementation Details

### Serialization Format

The persistence layer uses Erlang's `:ets.tab2file/2` and `:ets.file2tab/1` for efficient binary serialization:

- **Fast**: Direct ETS table serialization
- **Compact**: Binary format, no text overhead
- **Native**: Built into Erlang/OTP, no dependencies
- **Reliable**: ETS format is stable and well-tested

### Concurrency

The persistence layer handles concurrent access safely:

- **Saves**: Last write wins (multiple saves overwrite)
- **Loads**: Multiple loads can occur simultaneously
- **Validation**: Atomic metadata checks

### Error Handling

The system handles errors gracefully:

- **Corrupted cache**: Logs error, continues without cache
- **Missing metadata**: Treats as invalid, skips loading
- **I/O errors**: Logs and continues (won't crash application)

All errors are logged at appropriate levels (warning/error) for debugging.

## Configuration

### Cache Root Directory

Override the default cache location:

```elixir
# In config/config.exs
config :ragex, :cache_root, "/custom/path/to/cache"
```

### Disable Caching (Not Recommended)

To disable persistence entirely:

```elixir
# In config/config.exs
config :ragex, :cache, enabled: false
```

**Note**: Disabling caching will significantly impact startup performance.

## Incremental Updates (Phase 4C)

Ragex implements smart incremental updates to minimize embedding regeneration when files change.

### How It Works

1. **File Tracking**: Each analyzed file's content hash (SHA256) is stored
2. **Change Detection**: Before re-analyzing, files are checked for changes
3. **Selective Updates**: Only changed files are re-analyzed
4. **Entity Mapping**: Files are mapped to their entities (modules, functions)
5. **Minimal Regeneration**: Typically <5% regeneration on single-file changes

### Usage

#### Automatic (Default)

Incremental updates are automatic when using the analysis tools:

```bash
# This will skip unchanged files
mix ragex.cache.refresh
```

#### Force Full Refresh

To force re-analysis of all files:

```bash
mix ragex.cache.refresh --full
```

#### Check What Would Be Updated

```bash
# View tracking statistics
mix ragex.cache.stats
```

### Performance Impact

| Scenario | Files Changed | Regeneration % | Time (1,000 entities) |
|----------|---------------|----------------|------------------------|
| No changes | 0 | 0% | <1s |
| Single file | 1 | ~0.1% | ~2s |
| Module rename | 1-5 | ~0.5% | ~3s |
| Refactoring | 10-20 | ~2% | ~5s |
| Full refresh | All | 100% | 50-60s |

### File Tracking Data

For each tracked file, the system stores:

```elixir
%{
  path: "/path/to/file.ex",
  content_hash: <<...>>,              # SHA256 of content
  mtime: 1735565925,                  # Unix timestamp
  size: 1024,                         # File size in bytes
  entities: [                         # Entities in this file
    {:module, "MyModule"},
    {:function, {"MyModule", "foo", 0}}
  ],
  analyzed_at: 1735565925             # When analyzed
}
```

### Change Detection

Files are categorized as:

- **New**: File never analyzed before → analyze
- **Changed**: Content hash differs → re-analyze
- **Unchanged**: Content hash matches → skip
- **Deleted**: File no longer exists → remove entities

### Handling Edge Cases

#### File Renames

- Old path: Treated as deleted
- New path: Treated as new file
- Entities regenerated (necessary due to path references)

#### File Moves

Same as renames - content may be identical but path changes require updates.

#### Mass Refactoring

If >50% of files change, the system automatically marks it as a significant update but still only processes changed files.

### Integration

Incremental updates integrate seamlessly:

- **Automatic**: Enabled by default in all analysis operations
- **Persistent**: File tracking saved with embeddings cache
- **Compatible**: Works with all embedding models
- **Transparent**: No code changes needed

## Future Enhancements

Planned improvements:

- **Compression**: Optional gzip compression for large caches
- **Cache Expiry**: Automatic cleanup based on project activity
- **Migration Tools**: Automated cache migration for model upgrades
- **Smart Preloading**: Predict which files are likely to change

## Related Documentation

- [CONFIGURATION.md](CONFIGURATION.md) - Embedding model configuration
- [README.md](README.md) - Main project documentation
- [Mix Tasks](#cache-management) - Cache management commands
