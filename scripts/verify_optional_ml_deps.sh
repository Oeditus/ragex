#!/usr/bin/env bash
#
# Verifies that ragex compiles and Ragex.Application boots successfully when
# the optional native/NIF-backed dependencies (bumblebee, nx, exla, image)
# are genuinely absent from the dependency tree -- not merely unstarted via
# `config :ragex, skip_bumblebee: true`.
#
# This mirrors the scenario a downstream consumer (e.g. `mix escript.build`
# in a sibling project) hits: those NIFs cannot load from inside an escript
# archive, so they must be removable without breaking compilation or boot.
#
# Usage:
#   scripts/verify_optional_ml_deps.sh
#
# The script operates on a throwaway copy of the repository in a temporary
# directory; it never modifies the working tree it is run from.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d /tmp/ragex_no_ml_deps.XXXXXX)"

cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

echo "==> Copying repository to ${WORKDIR}"
rsync -a \
  --exclude='_build' \
  --exclude='deps' \
  --exclude='.git' \
  --exclude='.dialyzer' \
  --exclude='cover' \
  "${REPO_ROOT}/" "${WORKDIR}/"

cd "${WORKDIR}"

echo "==> Removing bumblebee/nx/exla/image from mix.exs"
sed -i \
  -e '/{:bumblebee, "~> 0.5", optional: true},/d' \
  -e '/{:nx, "~> 0.12", optional: true},/d' \
  -e '/{:exla, "~> 0.9", optional: true},/d' \
  -e '/{:image, "~> 0.54", optional: true},/d' \
  mix.exs

if grep -qE '\{:bumblebee|\{:nx,|\{:exla|\{:image' mix.exs; then
  echo "FAILED: mix.exs still references one of bumblebee/nx/exla/image" >&2
  grep -nE '\{:bumblebee|\{:nx,|\{:exla|\{:image' mix.exs >&2
  exit 1
fi

echo "==> Fetching dependencies without bumblebee/nx/exla/image"
mix deps.get || { echo "FAILED: mix deps.get" >&2; exit 1; }

if [ -d deps/bumblebee ] || [ -d deps/nx ] || [ -d deps/exla ] || [ -d deps/image ]; then
  echo "FAILED: one of bumblebee/nx/exla/image is still present under deps/" >&2
  exit 1
fi

echo "==> Compiling (warnings are not fatal, but the build must succeed)"
mix compile || { echo "FAILED: mix compile" >&2; exit 1; }

echo "==> Booting Ragex.Application with bumblebee/nx/exla/image absent"
mix run --no-start -e '
  Application.put_env(:ragex, :start_server, false)
  Application.put_env(:ragex, :start_stdio_server, false)
  Application.put_env(:ragex, :start_api, false)

  case Application.ensure_all_started(:ragex) do
    {:ok, _apps} ->
      IO.puts("BOOT_OK")
      IO.puts("bumblebee_available=#{Ragex.Embeddings.Bumblebee.available?()}")
      IO.puts("image_available=#{Ragex.Image.available?()}")
      IO.puts("embed_result=#{inspect(Ragex.Embeddings.Bumblebee.embed("hello"))}")

    {:error, reason} ->
      IO.puts("BOOT_FAILED: #{inspect(reason)}")
      System.halt(1)
  end
' || { echo "FAILED: boot smoke test" >&2; exit 1; }

echo "==> SUCCESS: ragex compiles and boots without bumblebee/nx/exla/image"
