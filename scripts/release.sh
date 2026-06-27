#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
DIST_DIR="$PROJECT_DIR/dist"

VERSION="${1:-$(git -C "$PROJECT_DIR" describe --tags --always --dirty 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION#v}"

if [[ -z "$VERSION" ]]; then
    echo "Error: could not determine version" >&2
    exit 1
fi

echo "Building Spaceballs v$VERSION for release..."

cd "$PROJECT_DIR"
VERSION="$VERSION" "$SCRIPT_DIR/bundle.sh" release

GUI_APP="$BUILD_DIR/release/Spaceballs.app"
CLI_APP="$BUILD_DIR/release/Spaceballs-CLI.app"
RELEASE_ROOT="$BUILD_DIR/release/spaceballs-$VERSION"
PAYLOAD_GUI_APP="$RELEASE_ROOT/Spaceballs.app"
PAYLOAD_CLI_APP="$RELEASE_ROOT/Spaceballs-CLI.app"

notarize_if_configured() {
    local notary_zip="$BUILD_DIR/release/spaceballs-notary.zip"

    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${TEAM_ID:-}" ]]; then
        echo "Submitting release bundle to Apple notary service..."
        codesign --verify --deep --strict --verbose=2 "$PAYLOAD_GUI_APP"
        codesign --verify --deep --strict --verbose=2 "$PAYLOAD_CLI_APP"
        rm -f "$notary_zip"
        ditto -c -k "$RELEASE_ROOT" "$notary_zip"
        xcrun notarytool submit "$notary_zip" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --team-id "$TEAM_ID" \
            --wait
    elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
        echo "Submitting release bundle to Apple notary service with profile: $NOTARY_PROFILE"
        codesign --verify --deep --strict --verbose=2 "$PAYLOAD_GUI_APP"
        codesign --verify --deep --strict --verbose=2 "$PAYLOAD_CLI_APP"
        rm -f "$notary_zip"
        ditto -c -k "$RELEASE_ROOT" "$notary_zip"
        xcrun notarytool submit "$notary_zip" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait
    else
        echo "Skipping notarization; APPLE_ID/APPLE_APP_PASSWORD/TEAM_ID or NOTARY_PROFILE not set."
        return
    fi

    echo "Stapling notarization tickets..."
    xcrun stapler staple "$PAYLOAD_GUI_APP"
    xcrun stapler validate "$PAYLOAD_GUI_APP"
    xcrun stapler staple "$PAYLOAD_CLI_APP"
    xcrun stapler validate "$PAYLOAD_CLI_APP"
    rm -f "$notary_zip"
}

echo "Preparing release payload..."
rm -rf "$RELEASE_ROOT"
mkdir -p "$RELEASE_ROOT"
cp -R "$GUI_APP" "$RELEASE_ROOT/"
cp -R "$CLI_APP" "$RELEASE_ROOT/"

notarize_if_configured

mkdir -p "$DIST_DIR"
ARCHIVE_NAME="spaceballs-${VERSION}-macos.tar.gz"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"

echo "Creating archive: $ARCHIVE_NAME"
rm -f "$ARCHIVE_PATH"
tar -czf "$ARCHIVE_PATH" -C "$RELEASE_ROOT" Spaceballs.app Spaceballs-CLI.app

SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | cut -d' ' -f1)"

echo ""
echo "=== Release Build Complete ==="
echo "Archive: $ARCHIVE_PATH"
echo "SHA256:  $SHA256"
echo ""
echo "To create a GitHub release:"
echo "  gh release create v$VERSION $ARCHIVE_PATH --title \"v$VERSION\" --notes \"Release v$VERSION\""

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "archive_path=$ARCHIVE_PATH" >> "$GITHUB_OUTPUT"
    echo "archive_name=$ARCHIVE_NAME" >> "$GITHUB_OUTPUT"
    echo "sha256=$SHA256" >> "$GITHUB_OUTPUT"
    echo "version=$VERSION" >> "$GITHUB_OUTPUT"
fi
