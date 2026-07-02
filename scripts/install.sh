#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# SHARIBAKO_INSTALL_DIR: where the `sharibako` symlink/binary lands.
# SHARIBAKO_BUNDLE_DIR: permanent home for the signed app bundle (macOS only).
# Override either via environment variable; defaults require write access to /usr/local.
DEST="${SHARIBAKO_INSTALL_DIR:-/usr/local/bin}"
BUNDLE_INSTALL_DIR="${SHARIBAKO_BUNDLE_DIR:-/usr/local/lib/sharibako}"

cd "$REPO_ROOT"
echo "Building sharibako (release)..."
swift build -c release --product sharibako
BINARY_PATH="$REPO_ROOT/.build/release/sharibako"

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "Error: build succeeded but binary not found at $BINARY_PATH" >&2
    exit 1
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
    SIGNING_IDENTITY="Developer ID Application: ANDREW TODD MARCUS (3N8F759K8D)"
    ENTITLEMENTS="$REPO_ROOT/sharibako.entitlements"
    PROVISION_PROFILE="$REPO_ROOT/scripts/Sharibako_Developer_ID.provisionprofile"

    if ! security find-identity -v -p codesigning | grep -q "3N8F759K8D"; then
        echo "Error: signing identity '$SIGNING_IDENTITY' not found in Keychain." >&2
        echo "Install your Developer ID Application cert (Apple Developer portal → Certificates)." >&2
        exit 1
    fi

    if [[ ! -f "$PROVISION_PROFILE" ]]; then
        echo "Error: provisioning profile not found at $PROVISION_PROFILE" >&2
        echo "Download 'Sharibako Developer ID' from developer.apple.com → Profiles" >&2
        echo "and place it at scripts/Sharibako_Developer_ID.provisionprofile" >&2
        exit 1
    fi

    # keychain-access-groups (required for biometric Keychain on modern macOS)
    # is a restricted entitlement that macOS only honours when the binary lives
    # inside an app bundle with an embedded provisioning profile. Build a thin
    # bundle, sign it, install it permanently, then symlink the binary into DEST.
    BUNDLE_WORK="$(mktemp -d /tmp/sharibako-bundle-XXXX)"
    APP="$BUNDLE_WORK/sharibako.app"
    mkdir -p "$APP/Contents/MacOS"
    cp "$BINARY_PATH" "$APP/Contents/MacOS/sharibako"

    cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>net.sageframe.sharibako</string>
    <key>CFBundleName</key>
    <string>sharibako</string>
    <key>CFBundleExecutable</key>
    <string>sharibako</string>
    <key>CFBundlePackageType</key>
    <string>TOOL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

    cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"

    echo "Signing sharibako with Developer ID..."
    codesign \
        --sign "$SIGNING_IDENTITY" \
        --identifier "net.sageframe.sharibako" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp \
        --force \
        "$APP"

    echo "Verifying signature..."
    codesign --verify --verbose "$APP"

    # Install the bundle permanently and clean up the build workspace.
    rm -rf "$BUNDLE_INSTALL_DIR/sharibako.app"
    mkdir -p "$BUNDLE_INSTALL_DIR"
    cp -R "$APP" "$BUNDLE_INSTALL_DIR/sharibako.app"
    rm -rf "$BUNDLE_WORK"

    # Symlink the binary into DEST. Following the symlink leads back into the
    # bundle, so macOS finds the bundle structure and honours the entitlements.
    mkdir -p "$DEST"
    ln -sf "$BUNDLE_INSTALL_DIR/sharibako.app/Contents/MacOS/sharibako" "$DEST/sharibako"
    echo "Installed sharibako bundle to $BUNDLE_INSTALL_DIR/sharibako.app"
    echo "Linked $DEST/sharibako → bundle"
else
    echo "Signing skipped (not macOS: $(uname -s))."
    mkdir -p "$DEST"
    install -m 0755 "$BINARY_PATH" "$DEST/sharibako"
    echo "Installed sharibako to $DEST/sharibako"
fi

"$DEST/sharibako" --version
