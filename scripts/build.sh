#!/bin/bash
# Cross-compile caido-mcp-server and caido-cli for release.
# Usage: ./scripts/build.sh [VERSION]
# Output: dist/

set -euo pipefail

VERSION="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${ROOT}/dist"
PLATFORMS=("darwin/amd64" "darwin/arm64" "linux/amd64" "linux/arm64")

rm -rf "$DIST"
mkdir -p "$DIST"

echo "Building $VERSION for ${#PLATFORMS[@]} targets..."

for platform in "${PLATFORMS[@]}"; do
  GOOS="${platform%/*}"
  GOARCH="${platform#*/}"
  suffix="${GOOS}-${GOARCH}"

  echo "  ${suffix}"

  # MCP server
  GOOS="$GOOS" GOARCH="$GOARCH" CGO_ENABLED=0 \
    go build -C "$ROOT" -ldflags="-s -w -X main.version=${VERSION}" \
    -o "${DIST}/caido-mcp-server-${suffix}" ./cmd/mcp

  # CLI
  GOOS="$GOOS" GOARCH="$GOARCH" CGO_ENABLED=0 \
    go build -C "$ROOT" -ldflags="-s -w" \
    -o "${DIST}/caido-cli-${suffix}" ./cmd/cli
done

echo ""
echo "Binaries in ${DIST}/:"
ls -lh "$DIST/"
