#!/bin/bash
# Docker build script for Ragex
# Downloads models and builds Docker image

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
IMAGE_NAME="ragex"
IMAGE_TAG="latest"
DOWNLOAD_ALL_MODELS=false
NO_CACHE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --all-models)
      DOWNLOAD_ALL_MODELS=true
      shift
      ;;
    --no-cache)
      NO_CACHE=true
      shift
      ;;
    --tag)
      IMAGE_TAG="$2"
      shift 2
      ;;
    --name)
      IMAGE_NAME="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --all-models    Download all available models (increases image size)"
      echo "  --no-cache      Build without using Docker cache"
      echo "  --tag TAG       Set image tag (default: latest)"
      echo "  --name NAME     Set image name (default: ragex)"
      echo "  -h, --help      Show this help message"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      exit 1
      ;;
  esac
done

echo -e "${GREEN}Ragex Docker Build Script${NC}"
echo "=========================="
echo ""
echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo "Download all models: ${DOWNLOAD_ALL_MODELS}"
echo "No cache: ${NO_CACHE}"
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed or not in PATH${NC}"
    exit 1
fi

# Check if we're in the right directory
if [ ! -f "mix.exs" ]; then
    echo -e "${RED}Error: Must be run from the Ragex project root directory${NC}"
    exit 1
fi

# Prepare Dockerfile modifications if needed
DOCKERFILE="Dockerfile"
TEMP_DOCKERFILE=""

if [ "$DOWNLOAD_ALL_MODELS" = true ]; then
    echo -e "${YELLOW}Creating modified Dockerfile to download all models...${NC}"
    TEMP_DOCKERFILE="Dockerfile.tmp"
    sed 's/mix ragex.models.download --quiet/mix ragex.models.download --all --quiet/' "$DOCKERFILE" > "$TEMP_DOCKERFILE"
    DOCKERFILE="$TEMP_DOCKERFILE"
fi

# Build Docker image
echo -e "${GREEN}Building Docker image...${NC}"
echo ""

BUILD_ARGS=()
if [ "$NO_CACHE" = true ]; then
    BUILD_ARGS+=("--no-cache")
fi

if docker build "${BUILD_ARGS[@]}" -f "$DOCKERFILE" -t "${IMAGE_NAME}:${IMAGE_TAG}" .; then
    echo ""
    echo -e "${GREEN}Build successful!${NC}"
    echo ""
    echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
    
    # Show image size
    IMAGE_SIZE=$(docker images "${IMAGE_NAME}:${IMAGE_TAG}" --format "{{.Size}}")
    echo "Size: ${IMAGE_SIZE}"
    echo ""
    
    # Cleanup temp Dockerfile
    if [ -n "$TEMP_DOCKERFILE" ] && [ -f "$TEMP_DOCKERFILE" ]; then
        rm "$TEMP_DOCKERFILE"
    fi
    
    echo -e "${GREEN}Next steps:${NC}"
    echo "  Run the container: docker run -i ${IMAGE_NAME}:${IMAGE_TAG}"
    echo "  Or with compose: docker-compose up"
    echo ""
    echo "See DOCKER.md for more information."
else
    echo ""
    echo -e "${RED}Build failed!${NC}"
    
    # Cleanup temp Dockerfile
    if [ -n "$TEMP_DOCKERFILE" ] && [ -f "$TEMP_DOCKERFILE" ]; then
        rm "$TEMP_DOCKERFILE"
    fi
    
    exit 1
fi
