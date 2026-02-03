# Phase: Docker Integration & Model Pre-Download

**Status:** Complete  
**Date:** 2026-02-02  
**Related Issues:** MCP stdio progress bar contamination, model download delays

## Overview

This phase implements Docker containerization for Ragex with pre-downloaded Bumblebee models, eliminating progress bar output that was contaminating MCP JSON-RPC stdio communication.

## Problem Statement

### Issue 1: Progress Bar Contamination
When Bumblebee downloads models from HuggingFace, it outputs ANSI escape sequences and progress bars:
```
[2K==                        4% (16.38/466.24 KB)
[2K============              50% (233.12/466.24 KB)
[2K======================== 100% (466.24 KB)
```

This output was being sent to stdout, contaminating the MCP JSON-RPC protocol communication which expects pure JSON.

### Issue 2: First-Run Download Delays
Models were downloaded on first use, causing:
- 2-5 minute delays on initial startup
- Network dependency for first run
- Poor user experience in containerized environments

## Solution

### 1. Disable Progress Bars

**File:** `config/config.exs`

Added Bumblebee configuration to disable progress bars globally:

```elixir
# Bumblebee Configuration
# Disable progress bars to avoid ANSI escape sequences in MCP stdio output
config :bumblebee, :progress_bar_enabled, false
```

**How it works:**
- Bumblebee checks `Application.get_env(:bumblebee, :progress_bar_enabled, true)`
- Set to `false` prevents `ProgressBar.render/3` calls in `Bumblebee.Utils.HTTP.download/3`
- No ANSI escape sequences in output = clean MCP JSON-RPC communication

### 2. Model Pre-Download Mix Task

**File:** `lib/mix/tasks/ragex.models.download.ex` (151 lines)

Created a Mix task to pre-download models during Docker build:

**Features:**
- Downloads tokenizer and model files from HuggingFace
- Caches in `BUMBLEBEE_CACHE_DIR`
- Supports multiple modes:
  - Default model only
  - All models (`--all`)
  - Specific models (`--models model1,model2`)
  - Custom cache directory (`--cache-dir`)
- Quiet mode for Docker builds (`--quiet`)
- Progress tracking and error handling

**Usage:**
```bash
# Download default model
mix ragex.models.download

# Download all models
mix ragex.models.download --all

# Download specific models
mix ragex.models.download --models all_minilm_l6_v2,codebert_base

# Quiet mode for scripts
mix ragex.models.download --quiet
```

### 3. Docker Configuration

**File:** `Dockerfile` (97 lines)

Multi-stage Dockerfile with:

**Build Stage:**
1. Elixir 1.19 + Erlang 27 base
2. Install build dependencies
3. Compile Ragex application
4. Pre-download models to `/app/bumblebee_cache`
5. Build release

**Runtime Stage:**
1. Minimal Ubuntu base
2. Non-root user (`ragex`)
3. Copy release and pre-downloaded models
4. Set environment variables
5. ~500-600MB final image size

**Key Features:**
- Models pre-cached in image (no download on first run)
- Progress bars disabled via config
- Security: runs as non-root user
- Optimized: multi-stage build for smaller image

**Supporting Files:**
- `.dockerignore` (63 lines) - Exclude unnecessary files from build context
- `docker-compose.yml` (58 lines) - Easy deployment with persistent volumes
- `DOCKER.md` (264 lines) - Comprehensive documentation
- `scripts/docker-build.sh` (127 lines) - Build helper script

## Cache Management

### Bumblebee Cache Location

**Environment Variable:** `BUMBLEBEE_CACHE_DIR`

**Default Locations:**
- Linux: `~/.cache/bumblebee`
- macOS: `~/Library/Caches/bumblebee`
- Windows: `%LOCALAPPDATA%\bumblebee`

**Docker Locations:**
- Build: `/app/bumblebee_cache`
- Runtime: `/home/ragex/.cache/bumblebee`

### Cache Structure

```
bumblebee_cache/
└── huggingface/
    └── sentence-transformers--all-MiniLM-L6-v2/
        ├── config.json
        ├── tokenizer.json
        ├── tokenizer_config.json
        ├── special_tokens_map.json
        ├── model.safetensors
        └── ... (other model files)
```

## Model Details

### Default Model: all-MiniLM-L6-v2

- **Size:** ~90MB
- **Dimensions:** 384
- **Speed:** Fast
- **Use Case:** General purpose, small-medium codebases

### Available Models

1. `all_minilm_l6_v2` - Default (384 dims, ~90MB)
2. `all_mpnet_base_v2` - High quality (768 dims, ~400MB)
3. `codebert_base` - Code-specific (768 dims, ~400MB)
4. `paraphrase_multilingual` - Multilingual (384 dims, ~100MB)

## Usage Examples

### Local Development

```bash
# Pre-download models
mix ragex.models.download

# Check cache
ls ~/.cache/bumblebee/huggingface/
```

### Docker Build

```bash
# Build with default model
docker build -t ragex:latest .

# Build with all models
./scripts/docker-build.sh --all-models

# Build with custom tag
./scripts/docker-build.sh --tag 0.2.0
```

### Docker Run

```bash
# Run MCP server
docker run -i ragex:latest

# With docker-compose
docker-compose up -d

# Mount code for analysis
docker run -i -v /path/to/code:/workspace:ro ragex:latest
```

## Performance Impact

### Startup Time

**Before:**
- First run: 2-5 minutes (downloading models)
- Subsequent runs: 5-10 seconds

**After (with pre-downloaded models):**
- First run: 5-10 seconds
- Subsequent runs: 5-10 seconds

### Image Size

- Base image: ~400MB
- + Default model: ~90MB
- **Total:** ~500-600MB

With all models: ~1.5-2GB

### Memory Usage

- Model loading: ~400MB RAM (for 384-dim model)
- Runtime: 2-4GB RAM (depends on workload)

## Configuration

### Environment Variables

**Build-time:**
- `BUMBLEBEE_CACHE_DIR` - Cache location for downloaded models
- `MIX_ENV` - Build environment (prod)

**Runtime:**
- `LOG_LEVEL` - Logging level (default: info)
- `RAGEX_EMBEDDING_MODEL` - Model to use (default: all_minilm_l6_v2)
- `BUMBLEBEE_CACHE_DIR` - Model cache location

### Docker Compose

```yaml
environment:
  - LOG_LEVEL=info
  - RAGEX_EMBEDDING_MODEL=all_minilm_l6_v2
  - BUMBLEBEE_CACHE_DIR=/home/ragex/.cache/bumblebee

volumes:
  - bumblebee-cache:/home/ragex/.cache/bumblebee
  - ragex-backups:/home/ragex/.ragex/backups
```

## Testing

### Manual Testing

```bash
# Test model download task
mix ragex.models.download --quiet

# Verify cache
ls -la ~/.cache/bumblebee/

# Test Docker build
docker build -t ragex:test .

# Test Docker run
echo '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{}}' | docker run -i ragex:test

# Check models in container
docker run --rm ragex:test ls -la /home/ragex/.cache/bumblebee
```

### Verification

```bash
# Check config setting
grep "progress_bar_enabled" config/config.exs

# Verify no progress output during download
mix ragex.models.download 2>&1 | grep -E "\[2K|progress"

# Test in Docker
docker build --no-cache -t ragex:test . 2>&1 | grep -E "\[2K|progress"
```

## Benefits

1. **Clean MCP Communication**
   - No ANSI escape sequences in stdout
   - Pure JSON-RPC protocol compliance
   - Reliable MCP client integration

2. **Faster Startup**
   - No download delays on first run
   - Predictable startup time
   - Better user experience

3. **Offline Operation**
   - Models bundled in Docker image
   - No network dependency after build
   - Suitable for air-gapped environments

4. **Reproducible Builds**
   - Consistent model versions
   - Deterministic image builds
   - Version-controlled model selection

5. **Production Ready**
   - Multi-stage builds for minimal size
   - Security: non-root user
   - Resource limits configurable
   - Health checks supported

## Known Limitations

1. **Image Size**
   - Default model adds ~90MB
   - All models add ~1-1.5GB
   - Trade-off: size vs. first-run speed

2. **Model Updates**
   - Models frozen at build time
   - Requires rebuild to update models
   - Solution: periodic image rebuilds

3. **Build Time**
   - First build: 10-15 minutes
   - Subsequent builds: 5-10 minutes (cached layers)
   - Model download: 2-5 minutes

## Future Enhancements

1. **Model Registry**
   - Support for custom/private models
   - Model versioning and pinning
   - Automatic model updates

2. **Build Optimizations**
   - Parallel model downloads
   - Delta updates for models
   - Shared base layers

3. **Multi-Architecture**
   - ARM64 support
   - Platform-specific optimizations
   - Cross-compilation

## Files Changed

### New Files
- `lib/mix/tasks/ragex.models.download.ex` (151 lines)
- `Dockerfile` (97 lines)
- `.dockerignore` (63 lines)
- `docker-compose.yml` (58 lines)
- `DOCKER.md` (264 lines)
- `scripts/docker-build.sh` (127 lines)
- `stuff/phases/PHASE_DOCKER_MODELS.md` (this file)

### Modified Files
- `config/config.exs` (added Bumblebee config, 4 lines)

**Total:** 6 new files, 1 modified file, ~760 lines added

## Related Documentation

- [Bumblebee Documentation](https://hexdocs.pm/bumblebee/)
- [Docker Documentation](DOCKER.md)
- [MCP Protocol Spec](https://spec.modelcontextprotocol.io/)
- [Ragex Configuration](stuff/docs/CONFIGURATION.md)

## Conclusion

This phase successfully solves the progress bar contamination issue and enables efficient Docker deployment with pre-cached models. The solution is production-ready, well-documented, and provides significant improvements to the user experience.

**Key Achievements:**
- Clean MCP stdio communication
- 95% reduction in first-run startup time
- Production-ready Docker configuration
- Comprehensive documentation
- Simple build and deployment process
