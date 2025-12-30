# Ragex Configuration Guide

This document covers all configuration options for Ragex, including embedding models, caching, and performance tuning.

## Table of Contents

- [Embedding Models](#embedding-models)
- [Configuration Methods](#configuration-methods)
- [Available Models](#available-models)
- [Model Selection Guide](#model-selection-guide)
- [Cache Configuration](#cache-configuration)
- [Migration Guide](#migration-guide)
- [Performance Tuning](#performance-tuning)

## Embedding Models

Ragex supports multiple embedding models for semantic code search. The model choice affects:
- **Quality**: Accuracy of semantic search results
- **Speed**: Embedding generation and search time
- **Memory**: RAM required to load the model
- **Dimensions**: Vector size (impacts storage and similarity computation)

### Default Model

By default, Ragex uses **all-MiniLM-L6-v2**:
- ✅ Fast inference (384 dimensions)
- ✅ Small model size (~90MB)
- ✅ Good quality for general-purpose search
- ✅ Suitable for small to medium codebases

## Configuration Methods

### 1. Via `config/config.exs` (Recommended)

```elixir
import Config

# Set embedding model
config :ragex, :embedding_model, :all_minilm_l6_v2

# Available options:
# :all_minilm_l6_v2       (default)
# :all_mpnet_base_v2      (high quality)
# :codebert_base          (code-specific)
# :paraphrase_multilingual (multilingual)
```

### 2. Via Environment Variable

```bash
export RAGEX_EMBEDDING_MODEL=codebert_base
mix run --no-halt
```

This overrides `config.exs` settings.

### 3. Checking Current Configuration

```bash
mix ragex.embeddings.migrate --check
```

Output example:
```
Checking embedding model status...

✓ Configured Model: all-MiniLM-L6-v2
  ID: all_minilm_l6_v2
  Dimensions: 384
  Type: sentence_transformer
  Repository: sentence-transformers/all-MiniLM-L6-v2

✓ No embeddings stored yet

Available Models:
  • all_minilm_l6_v2 (current)
    all-MiniLM-L6-v2 - 384 dims
  • all_mpnet_base_v2
    all-mpnet-base-v2 - 768 dims
  • codebert_base
    CodeBERT Base - 768 dims
  • paraphrase_multilingual
    paraphrase-multilingual-MiniLM-L12-v2 - 384 dims
```

## Available Models

### 1. all-MiniLM-L6-v2 (Default)

**Model ID:** `:all_minilm_l6_v2`

**Specifications:**
- **Dimensions:** 384
- **Max tokens:** 256
- **Type:** Sentence transformer
- **Model size:** ~90MB

**Best for:**
- ✅ General-purpose semantic search
- ✅ Small to medium codebases (<10k entities)
- ✅ Fast inference requirements
- ✅ Limited memory environments

**Performance:**
- Embedding generation: ~50ms per entity
- Memory usage: ~400MB (model + runtime)
- Quality: Good for most use cases

**Configuration:**
```elixir
config :ragex, :embedding_model, :all_minilm_l6_v2
```

---

### 2. all-mpnet-base-v2 (High Quality)

**Model ID:** `:all_mpnet_base_v2`

**Specifications:**
- **Dimensions:** 768
- **Max tokens:** 384
- **Type:** Sentence transformer
- **Model size:** ~420MB

**Best for:**
- ✅ Large codebases requiring high accuracy
- ✅ Deep semantic understanding
- ✅ When quality is more important than speed
- ✅ Complex domain-specific terminology

**Performance:**
- Embedding generation: ~100ms per entity
- Memory usage: ~800MB (model + runtime)
- Quality: Excellent semantic understanding

**Trade-offs:**
- ⚠️ 2x slower than all-MiniLM-L6-v2
- ⚠️ 2x more memory
- ⚠️ 2x larger embeddings (storage)

**Configuration:**
```elixir
config :ragex, :embedding_model, :all_mpnet_base_v2
```

---

### 3. CodeBERT Base (Code-Specific)

**Model ID:** `:codebert_base`

**Specifications:**
- **Dimensions:** 768
- **Max tokens:** 512
- **Type:** Code model
- **Model size:** ~500MB

**Best for:**
- ✅ Code similarity tasks
- ✅ Programming-specific queries
- ✅ Multi-language codebases
- ✅ API discovery and documentation search

**Performance:**
- Embedding generation: ~120ms per entity
- Memory usage: ~900MB (model + runtime)
- Quality: Optimized for code understanding

**Special features:**
- Pre-trained on code and natural language
- Better understanding of programming concepts
- Good for finding similar code patterns

**Configuration:**
```elixir
config :ragex, :embedding_model, :codebert_base
```

---

### 4. paraphrase-multilingual-MiniLM-L12-v2 (Multilingual)

**Model ID:** `:paraphrase_multilingual`

**Specifications:**
- **Dimensions:** 384
- **Max tokens:** 128
- **Type:** Multilingual
- **Model size:** ~110MB

**Best for:**
- ✅ International teams
- ✅ Non-English documentation
- ✅ Multilingual codebases (50+ languages)
- ✅ Mixed language comments/docs

**Performance:**
- Embedding generation: ~60ms per entity
- Memory usage: ~450MB (model + runtime)
- Quality: Good for multilingual content

**Supported languages:**
Arabic, Chinese, Dutch, English, French, German, Italian, Korean, Polish, Portuguese, Russian, Spanish, Turkish, and 37+ more

**Configuration:**
```elixir
config :ragex, :embedding_model, :paraphrase_multilingual
```

## Model Selection Guide

### Decision Tree

```
Do you have multilingual code/docs?
  ├─ YES → paraphrase_multilingual
  └─ NO  → Continue...

Is your codebase primarily code-focused?
  ├─ YES → codebert_base
  └─ NO  → Continue...

Do you need maximum quality?
  ├─ YES → all_mpnet_base_v2
  └─ NO  → all_minilm_l6_v2 (default)
```

### Use Case Recommendations

| Use Case | Recommended Model | Why |
|----------|------------------|-----|
| **Startup/Small Project** | all_minilm_l6_v2 | Fast, lightweight, good enough |
| **Enterprise/Large Codebase** | all_mpnet_base_v2 | Best quality, worth the cost |
| **Code-heavy (APIs, Libraries)** | codebert_base | Trained on code specifically |
| **International Team** | paraphrase_multilingual | Multi-language support |
| **Limited Memory (<4GB)** | all_minilm_l6_v2 | Smallest footprint |
| **Quality-Critical** | all_mpnet_base_v2 | Highest accuracy |

### Dimension Compatibility

Models with the **same dimensions** can share embeddings:

**384-dimensional models (compatible):**
- all_minilm_l6_v2
- paraphrase_multilingual

**768-dimensional models (compatible):**
- all_mpnet_base_v2
- codebert_base

You can switch between compatible models without regenerating embeddings!

## Cache Configuration

### Enable/Disable Cache

```elixir
config :ragex, :cache,
  enabled: true,  # Set to false to disable caching
  dir: Path.expand("~/.cache/ragex"),  # Cache directory
  max_age_days: 30  # Auto-cleanup after 30 days
```

### Cache Location

Default: `~/.cache/ragex/embeddings/<project_hash>.ets`

Custom location:
```elixir
config :ragex, :cache,
  enabled: true,
  dir: "/custom/path/to/cache"
```

### Cache Management Commands

```bash
# Show cache statistics
mix ragex.cache.stats

# Clear all caches
mix ragex.cache.clear

# Clear caches older than 7 days
mix ragex.cache.clear --older-than 7
```

## Migration Guide

### Switching Models

#### Scenario 1: Compatible Models (Same Dimensions)

**Example:** all_minilm_l6_v2 → paraphrase_multilingual (both 384 dims)

**Steps:**
1. Update `config/config.exs`:
   ```elixir
   config :ragex, :embedding_model, :paraphrase_multilingual
   ```

2. Restart the server:
   ```bash
   # Kill existing process
   # Then restart
   mix run --no-halt
   ```

3. ✅ Done! Existing embeddings still work.

---

#### Scenario 2: Incompatible Models (Different Dimensions)

**Example:** all_minilm_l6_v2 (384) → all_mpnet_base_v2 (768)

**Steps:**
1. Check current status:
   ```bash
   mix ragex.embeddings.migrate --check
   ```

2. Clear existing embeddings:
   ```bash
   # Stop the server
   # Embeddings are in-memory and will be cleared on restart
   ```

3. Update `config/config.exs`:
   ```elixir
   config :ragex, :embedding_model, :all_mpnet_base_v2
   ```

4. Restart and re-analyze:
   ```bash
   mix run --no-halt
   # Then analyze your codebase via MCP tools
   ```

---

### Using the Migration Tool

#### Check Status
```bash
mix ragex.embeddings.migrate --check
```

#### Plan Migration
```bash
mix ragex.embeddings.migrate --model codebert_base
```

This checks compatibility and provides instructions.

#### Force Migration
```bash
mix ragex.embeddings.migrate --model codebert_base --force
```

## Performance Tuning

### Memory Optimization

**For systems with limited memory (<4GB):**

1. Use lightweight model:
   ```elixir
   config :ragex, :embedding_model, :all_minilm_l6_v2
   ```

2. Limit batch size (in Bumblebee adapter):
   ```elixir
   compile: [batch_size: 16, sequence_length: 256]  # Reduce from 32
   ```

3. Disable cache if needed:
   ```elixir
   config :ragex, :cache, enabled: false
   ```

---

### Speed Optimization

**For faster embedding generation:**

1. Use faster model:
   ```elixir
   config :ragex, :embedding_model, :all_minilm_l6_v2
   ```

2. Reduce sequence length:
   ```elixir
   compile: [batch_size: 32, sequence_length: 256]  # Reduce from 512
   ```

3. Enable EXLA compiler (if not already):
   - Ensure `exla` dependency is included
   - First run will compile (slow), subsequent runs are fast

---

### Quality Optimization

**For best search quality:**

1. Use high-quality model:
   ```elixir
   config :ragex, :embedding_model, :all_mpnet_base_v2
   ```

2. Generate embeddings for all entities:
   ```elixir
   # In analyze_file MCP tool
   {
     "generate_embeddings": true  # Always true
   }
   ```

3. Use longer text descriptions:
   - Include more context in function/module docs
   - Better descriptions = better embeddings

---

## Environment-Specific Configuration

### Development
```elixir
# config/dev.exs
import Config

config :ragex, :embedding_model, :all_minilm_l6_v2  # Fast for dev
config :ragex, :cache, enabled: true  # Cache for quick restarts
```

### Production
```elixir
# config/prod.exs
import Config

config :ragex, :embedding_model, :all_mpnet_base_v2  # Quality for prod
config :ragex, :cache, enabled: true, max_age_days: 90  # Long cache
```

### Testing
```elixir
# config/test.exs
import Config

config :ragex, :embedding_model, :all_minilm_l6_v2  # Fast tests
config :ragex, :cache, enabled: false  # No cache for isolation
```

---

## Troubleshooting

### Model Won't Load

**Symptom:** "Failed to load Bumblebee model"

**Solutions:**
1. Check internet connection (first download)
2. Verify disk space (~500MB needed)
3. Check cache directory permissions: `~/.cache/huggingface/`
4. Try clearing HuggingFace cache:
   ```bash
   rm -rf ~/.cache/huggingface/
   ```

---

### Dimension Mismatch Error

**Symptom:** "Dimension mismatch: expected 384, got 768"

**Solution:**
```bash
mix ragex.embeddings.migrate --check
# Follow instructions to clear embeddings
# Then restart with new model
```

---

### Out of Memory

**Symptom:** Server crashes or freezes during embedding generation

**Solutions:**
1. Switch to smaller model:
   ```elixir
   config :ragex, :embedding_model, :all_minilm_l6_v2
   ```

2. Reduce batch size in code:
   ```elixir
   compile: [batch_size: 8, sequence_length: 256]
   ```

3. Increase system swap space

---

## Advanced Configuration

### Custom Model (Advanced)

To add a custom model, edit `lib/ragex/embeddings/registry.ex`:

```elixir
custom_model: %{
  id: :custom_model,
  name: "Custom Model",
  repo: "organization/model-name",
  dimensions: 512,
  max_tokens: 256,
  description: "My custom embedding model",
  type: :sentence_transformer,
  recommended_for: ["custom use case"]
}
```

Then configure:
```elixir
config :ragex, :embedding_model, :custom_model
```

---

## Summary

**Quick Start (Default):**
```elixir
# config/config.exs
config :ragex, :embedding_model, :all_minilm_l6_v2
```

**For Best Quality:**
```elixir
config :ragex, :embedding_model, :all_mpnet_base_v2
```

**For Code-Specific:**
```elixir
config :ragex, :embedding_model, :codebert_base
```

**For Multilingual:**
```elixir
config :ragex, :embedding_model, :paraphrase_multilingual
```

**Check Status Anytime:**
```bash
mix ragex.embeddings.migrate --check
```

---

## References

- [Sentence Transformers Documentation](https://www.sbert.net/)
- [HuggingFace Models](https://huggingface.co/models)
- [CodeBERT Paper](https://arxiv.org/abs/2002.08155)
- [Bumblebee Library](https://hexdocs.pm/bumblebee/)
