#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
RESOURCES_DIR="$PROJECT_DIR/Resources"

# Load local signing/notarization config when present. CI supplies these values
# through secrets instead.
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
    set +a
fi

BUILD_CONFIG="${1:-release}"
if [[ "$BUILD_CONFIG" != "debug" && "$BUILD_CONFIG" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 1
fi

if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(git -C "$PROJECT_DIR" describe --tags --always --dirty 2>/dev/null | sed 's/^v//')"
fi
VERSION="${VERSION:-0.0.0-dev}"

DISTRIBUTION_SIGNING=false
if [[ -n "${TEAM_NAME:-}" && -n "${TEAM_ID:-}" ]]; then
    SIGN_IDENTITY="Developer ID Application: $TEAM_NAME ($TEAM_ID)"
    DISTRIBUTION_SIGNING=true
elif [[ -z "${SIGN_IDENTITY:-}" ]]; then
    # Keep local app-bundle identity stable on machines that have the existing
    # development cert, but fall back to ad-hoc signing for fresh machines/CI.
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Spacebar Dev"'; then
        SIGN_IDENTITY="Spacebar Dev"
    else
        SIGN_IDENTITY="-"
    fi
fi

echo "Building Spaceballs ($BUILD_CONFIG, version $VERSION)..."

cd "$PROJECT_DIR"
swift build -c "$BUILD_CONFIG" --disable-sandbox --product spaceballs-gui
swift build -c "$BUILD_CONFIG" --disable-sandbox --product spaceballs

stamp_version() {
    local plist_path="$1"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist_path"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$plist_path"
}

create_bundle() {
    local app_name="$1"
    local product_name="$2"
    local plist_name="$3"

    local app_bundle="$BUILD_DIR/$BUILD_CONFIG/$app_name.app"
    local contents_dir="$app_bundle/Contents"
    local macos_dir="$contents_dir/MacOS"
    local resources_dir="$contents_dir/Resources"

    echo "Creating $app_name.app..."
    rm -rf "$app_bundle"
    mkdir -p "$macos_dir" "$resources_dir"

    cp "$BUILD_DIR/$BUILD_CONFIG/$product_name" "$macos_dir/spaceballs"
    cp "$RESOURCES_DIR/$plist_name" "$contents_dir/Info.plist"
    stamp_version "$contents_dir/Info.plist"
    echo -n "APPL????" > "$contents_dir/PkgInfo"
}

sign_bundle() {
    local app_bundle="$1"

    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "Signing $(basename "$app_bundle") ad-hoc..."
        codesign --force --deep --sign - "$app_bundle" 2>/dev/null || true
        return
    fi

    if [[ "$DISTRIBUTION_SIGNING" == true ]]; then
        echo "Signing $(basename "$app_bundle") with Developer ID: $SIGN_IDENTITY"
        codesign --force --deep \
            --options runtime \
            --timestamp \
            --sign "$SIGN_IDENTITY" \
            "$app_bundle"
    else
        echo "Signing $(basename "$app_bundle") with local identity: $SIGN_IDENTITY"
        codesign --force --deep --sign "$SIGN_IDENTITY" "$app_bundle"
    fi

    codesign --verify --deep --strict --verbose=2 "$app_bundle"
}

GUI_APP="$BUILD_DIR/$BUILD_CONFIG/Spaceballs.app"
CLI_APP="$BUILD_DIR/$BUILD_CONFIG/Spaceballs-CLI.app"

create_bundle "Spaceballs" "spaceballs-gui" "Info.plist"
create_bundle "Spaceballs-CLI" "spaceballs" "Info-CLI.plist"

COMPLETIONS_DIR="$CLI_APP/Contents/Resources/completions"
mkdir -p "$COMPLETIONS_DIR"
"$CLI_APP/Contents/MacOS/spaceballs" --generate-completion-script zsh > "$COMPLETIONS_DIR/_spaceballs"
"$CLI_APP/Contents/MacOS/spaceballs" --generate-completion-script bash > "$COMPLETIONS_DIR/spaceballs.bash"
"$CLI_APP/Contents/MacOS/spaceballs" --generate-completion-script fish > "$COMPLETIONS_DIR/spaceballs.fish"

sign_bundle "$GUI_APP"
sign_bundle "$CLI_APP"

echo ""
echo "Bundles created:"
echo "  $GUI_APP"
echo "  $CLI_APP"
