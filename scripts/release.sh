#!/bin/bash
set -euo pipefail

# Release script for spacebar
# Creates a distributable archive of the CLI binary

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"

# Get version from argument or Version.swift
VERSION="${1:-$(grep -o 'version = "[^"]*"' "$PROJECT_DIR/Sources/Spacebar/Version.swift" | head -1 | cut -d'"' -f2)}"

if [[ -z "$VERSION" ]]; then
    echo "Error: Could not determine version"
    exit 1
fi

echo "Building spacebar v$VERSION for release..."

# Build release binary
cd "$PROJECT_DIR"
swift build -c release --disable-sandbox

# Create dist directory
mkdir -p "$DIST_DIR"

# Create archive
BINARY=".build/release/spacebar"
ARCHIVE_NAME="spacebar-${VERSION}-macos.tar.gz"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"

echo "Creating archive: $ARCHIVE_NAME"

# Create tarball containing just the binary
tar -czf "$ARCHIVE_PATH" -C .build/release spacebar

# Calculate SHA256
SHA256=$(shasum -a 256 "$ARCHIVE_PATH" | cut -d' ' -f1)

echo ""
echo "=== Release Build Complete ==="
echo "Archive: $ARCHIVE_PATH"
echo "SHA256:  $SHA256"
echo ""
echo "To create a GitHub release:"
echo "  gh release create v$VERSION $ARCHIVE_PATH --title \"v$VERSION\" --notes \"Release v$VERSION\""
echo ""
echo "Homebrew formula URL (after release):"
echo "  https://github.com/moltenbits/spacebar/releases/download/v$VERSION/$ARCHIVE_NAME"
echo ""

# Output for CI
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "archive_path=$ARCHIVE_PATH" >> "$GITHUB_OUTPUT"
    echo "archive_name=$ARCHIVE_NAME" >> "$GITHUB_OUTPUT"
    echo "sha256=$SHA256" >> "$GITHUB_OUTPUT"
    echo "version=$VERSION" >> "$GITHUB_OUTPUT"
fi
