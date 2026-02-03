# Ragex Docker Guide

This guide explains how to build and run Ragex as a Docker container with pre-downloaded Bumblebee models.

## Features

- Multi-stage build for minimal image size
- Pre-downloaded Bumblebee models (no download on first run)
- Progress bar disabled for clean MCP stdio communication
- Non-root user for security
- Persistent volumes for caches and backups

## Quick Start

### Build the Image

```bash
docker build -t ragex:latest .
```

This will:
1. Compile the Elixir application
2. Download the default embedding model (all-MiniLM-L6-v2)
3. Create a minimal runtime image
4. Copy the pre-downloaded model to the final image

**Note:** The build process may take 10-15 minutes on first run due to model download.

### Run with Docker

```bash
docker run -i ragex:latest
```

The `-i` flag is required for stdio-based MCP communication.

### Run with Docker Compose

```bash
docker-compose up -d
```

## Configuration

### Environment Variables

Set these in `docker-compose.yml` or pass with `-e`:

- `LOG_LEVEL` - Logging level (default: `info`)
- `RAGEX_EMBEDDING_MODEL` - Model to use (default: `all_minilm_l6_v2`)
- `BUMBLEBEE_CACHE_DIR` - Cache directory (default: `/home/ragex/.cache/bumblebee`)

### Available Models

- `all_minilm_l6_v2` - Default, fast, 384 dimensions
- `all_mpnet_base_v2` - High quality, 768 dimensions
- `codebert_base` - Code-specific, 768 dimensions
- `paraphrase_multilingual` - Multilingual, 384 dimensions

### Pre-downloading All Models

To include all models in the Docker image:

```dockerfile
# In Dockerfile, replace line 46 with:
RUN mix ragex.models.download --all --quiet
```

This will increase image size significantly (~2-3GB per additional model).

## Advanced Usage

### Building with Specific Model

```bash
docker build \
  --build-arg RAGEX_MODEL=codebert_base \
  -t ragex:codebert \
  .
```

### Using as MCP Server

```json
{
  "mcpServers": {
    "ragex": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "ragex:latest"
      ]
    }
  }
}
```

### Mounting Code for Analysis

```bash
docker run -i \
  -v /path/to/code:/workspace:ro \
  ragex:latest
```

Then use MCP tools to analyze `/workspace`.

## Volumes

### Persistent Volumes

- `bumblebee-cache` - Model cache (pre-populated during build)
- `ragex-backups` - Editor backup files

### Host Mounts

```yaml
volumes:
  - ./my-project:/workspace:ro
  - ./logs:/app/logs
```

## Troubleshooting

### Models Not Found

If models aren't pre-downloaded, they'll be downloaded on first use. Check:

```bash
docker run --rm ragex:latest ls -la /home/ragex/.cache/bumblebee
```

### Build Fails During Model Download

The build continues even if model download fails. Models will download on first use instead:

```bash
# Check build logs
docker build --no-cache -t ragex:latest .
```

### Progress Bars in Output

If you see ANSI escape sequences (`[2K`, etc.), ensure:

1. `config :bumblebee, :progress_bar_enabled, false` is in `config/config.exs`
2. Rebuild the image: `docker build --no-cache -t ragex:latest .`

### Memory Issues

Bumblebee models require significant RAM:

```yaml
deploy:
  resources:
    limits:
      memory: 4G  # Increase if needed
```

## Model Cache Location

Models are cached at:
- **Build time:** `/app/bumblebee_cache`
- **Runtime:** `/home/ragex/.cache/bumblebee`

The cache directory is copied from build to runtime stage.

## Image Size

Approximate sizes:
- Base image: ~400MB
- + Default model: ~90MB
- + All models: ~400MB additional per model

Final image with default model: ~500-600MB

## Security

- Runs as non-root user `ragex` (UID 1000)
- No unnecessary packages in runtime image
- Read-only recommended for workspace mounts

## Development

### Testing Locally

```bash
# Download models locally first
mix ragex.models.download

# Run tests
mix test

# Build Docker image
docker build -t ragex:dev .
```

### Debugging the Container

```bash
docker run -it --entrypoint /bin/bash ragex:latest

# Inside container
ls -la /home/ragex/.cache/bumblebee
/app/bin/ragex version
```

## Performance

### First Run vs. Subsequent Runs

- **With pre-downloaded models:** ~5-10s startup
- **Without models:** ~2-5min first startup (downloading)

### Resource Usage

Typical usage:
- CPU: 0.5-2 cores during analysis
- RAM: 2-4GB (depends on model size)
- Disk: ~500MB for image + models

## Production Deployment

### Recommendations

1. Use specific version tags: `ragex:0.2.0` instead of `:latest`
2. Set resource limits in compose file
3. Configure health checks (if using socket mode)
4. Use persistent volumes for backups
5. Monitor logs: `docker logs -f ragex-mcp-server`

### Example Production Config

```yaml
services:
  ragex:
    image: ragex:0.2.0
    container_name: ragex-prod
    restart: always
    environment:
      - LOG_LEVEL=warning
    volumes:
      - /data/ragex/backups:/home/ragex/.ragex/backups
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 4G
```

## Related Documentation

- [Bumblebee Documentation](https://hexdocs.pm/bumblebee/)
- [MCP Protocol Specification](https://spec.modelcontextprotocol.io/)
- [Ragex README](README.md)

## Support

For issues related to:
- Docker build: Check build logs and ensure dependencies are met
- Model downloads: Verify internet connection and HuggingFace access
- Runtime errors: Check logs with `docker logs`
