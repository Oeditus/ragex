# Multi-stage Dockerfile for Ragex MCP Server
# Includes pre-downloaded Bumblebee models for offline use

# Stage 1: Build
FROM hexpm/elixir:1.19.0-erlang-27.2.1-ubuntu-noble-20250113 AS builder

# Install build dependencies
RUN apt-get update && \
    apt-get install -y \
    build-essential \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./

# Install dependencies
ENV MIX_ENV=prod
RUN mix deps.get --only prod && \
    mix deps.compile

# Copy application code
COPY config ./config
COPY lib ./lib
COPY priv ./priv

# Compile application
RUN mix compile

# Pre-download Bumblebee models
# Set cache directory to a known location that we'll copy to final image
ENV BUMBLEBEE_CACHE_DIR=/app/bumblebee_cache
ENV XLA_TARGET=cpu
ENV EXLA_TARGET=host

# Download the default model (all-MiniLM-L6-v2)
# Use --quiet to avoid progress bars, and handle the model download
RUN mix ragex.models.download --quiet || \
    echo "Warning: Model download failed, models will be downloaded on first use"

# Build release
RUN mix release

# Stage 2: Runtime
FROM ubuntu:noble-20250113

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y \
    openssl \
    libncurses6 \
    locales \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set locale
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create app user
RUN useradd -m -u 1000 -s /bin/bash ragex

# Set working directory
WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=ragex:ragex /app/_build/prod/rel/ragex ./

# Copy pre-downloaded models from builder
COPY --from=builder --chown=ragex:ragex /app/bumblebee_cache /home/ragex/.cache/bumblebee

# Set environment variables
ENV BUMBLEBEE_CACHE_DIR=/home/ragex/.cache/bumblebee
ENV XLA_TARGET=cpu
ENV EXLA_TARGET=host
ENV MIX_ENV=prod
ENV LOG_LEVEL=info

# Switch to app user
USER ragex

# Expose MCP server (stdio mode - no ports needed)
# Health check endpoint (if socket server is enabled)
EXPOSE 8080

# Default command: run MCP server via stdio
CMD ["/app/bin/ragex", "start"]
