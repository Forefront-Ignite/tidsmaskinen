#!/usr/bin/env bash
# Builds Tidsmaskinen.app — a proper macOS app bundle with a stable bundle
# identifier and signing identity so TCC (Accessibility, Automation) can
# track granted permissions and they survive rebuilds.
#
# - Bundle ID:        se.forefront.tidsmaskinen
# - Signing identity: a self-signed code-signing cert "Tidsmaskinen Self-Signed"
#                     created once in the user's login keychain. Without this,
#                     ad-hoc signing gives each rebuild a different cdhash and
#                     TCC treats it as a new app — Accessibility grants reset.
#
# Usage:   ./bin/make-app.sh [debug|release]
# Default: release

set -euo pipefail

CONFIG="${1:-release}"
case "$CONFIG" in
    debug|release) ;;
    *) echo "Unknown config '$CONFIG' — use debug or release" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="Tidsmaskinen"
BUNDLE_ID="se.forefront.tidsmaskinen"
VERSION="${VERSION:-0.1.0-dev}"
APP="$ROOT/$APP_NAME.app"
CERT_CN="Tidsmaskinen Self-Signed"

# CI / release knobs. Default to "off" so local dev keeps the self-signed path.
#   SIGNING_IDENTITY        Developer ID common name; unset => use self-signed
#   NOTARIZE                "1" => submit to notarytool and staple
#   SPARKLE_PUBLIC_ED_KEY   base64 EdDSA public key embedded in Info.plist
#   SPARKLE_FEED_URL        appcast URL embedded in Info.plist
#   APPLE_API_KEY_ID / APPLE_API_ISSUER_ID / APPLE_API_KEY_PATH
#                           App Store Connect API key for notarytool
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-0}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/Forefront-Ignite/tidsmaskinen/main/appcast.xml}"

# ---- Ensure stable signing identity --------------------------------------

ensure_signing_identity() {
    # Use `find-identity -p codesigning` *without* -v: a self-signed cert lacks
    # a trust chain, so it's CSSMERR_TP_NOT_TRUSTED, but codesign accepts it
    # for signing. -v would hide it.
    if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_CN\""; then
        return 0
    fi

    echo "==> Creating self-signed code-signing identity (one-time)"

    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    cat > "$tmp/req.cnf" <<CONF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca

[dn]
CN = $CERT_CN

[v3_ca]
basicConstraints = CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning,1.3.6.1.5.5.7.3.3
CONF

    if ! openssl req -newkey rsa:2048 -nodes \
            -keyout "$tmp/key.pem" \
            -x509 -days 3650 \
            -config "$tmp/req.cnf" \
            -out "$tmp/cert.pem" >/dev/null 2>&1; then
        echo "    ✗ openssl failed to generate cert" >&2
        return 1
    fi

    # IMPORTANT: openssl 3 produces PKCS#12 v3 with SHA-256 MAC, which
    # macOS's `security import` cannot verify. -legacy forces the v1 format
    # (PBE-SHA1-3DES + SHA-1 MAC) which security accepts. The password is
    # only for the import handshake; the keychain itself protects the key.
    local p12_pass="tidsmaskinen-import"
    if ! openssl pkcs12 -export -legacy \
            -out "$tmp/cert.p12" \
            -inkey "$tmp/key.pem" \
            -in "$tmp/cert.pem" \
            -name "$CERT_CN" \
            -password "pass:$p12_pass" \
            >/dev/null 2>&1; then
        echo "    ✗ openssl pkcs12 failed (your openssl may be too old for -legacy)" >&2
        return 1
    fi

    # -T /usr/bin/codesign grants the private key to codesign without a prompt.
    # Avoid -A (which authorises ALL applications to use the key); that's
    # broader than we need and a credential-stealing app could sign with it.
    if ! security import "$tmp/cert.p12" \
            -k "$HOME/Library/Keychains/login.keychain-db" \
            -P "$p12_pass" \
            -T /usr/bin/codesign >/dev/null 2>&1; then
        echo "    ✗ security import failed" >&2
        return 1
    fi

    if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_CN\""; then
        echo "    ✓ Created \"$CERT_CN\" (untrusted but usable for codesign)"
        return 0
    fi
    echo "    ✗ Identity not visible after import" >&2
    return 1
}

if [[ -n "$SIGNING_IDENTITY" ]]; then
    SIGN_IDENTITY="$SIGNING_IDENTITY"
    echo "==> Using signing identity from environment: $SIGN_IDENTITY"
elif ensure_signing_identity; then
    SIGN_IDENTITY="$CERT_CN"
else
    echo "==> Falling back to ad-hoc signature (TCC grants will reset on each rebuild)"
    SIGN_IDENTITY="-"
fi

# Apple's timestamp service refuses self-signed certs, so only request
# timestamping when notarizing (which already requires a real Developer ID).
TIMESTAMP_FLAG=""
if [[ "$NOTARIZE" == "1" ]]; then
    TIMESTAMP_FLAG="--timestamp"
fi

# ---- Build app icon -------------------------------------------------------

ICON_SRC="$ROOT/Resources/AppIcon.png"
ICON_OUT="$ROOT/Resources/AppIcon.icns"

build_icon() {
    [[ -f "$ICON_SRC" ]] || return 0
    # Skip if .icns is newer than the source PNG
    if [[ -f "$ICON_OUT" && "$ICON_OUT" -nt "$ICON_SRC" ]]; then
        return 0
    fi
    echo "==> Building AppIcon.icns from $(basename "$ICON_SRC")"
    local set
    set=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$set"
    local s
    for s in 16 32 128 256 512; do
        sips -z $s $s            "$ICON_SRC" --out "$set/icon_${s}x${s}.png"        >/dev/null
        sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out "$set/icon_${s}x${s}@2x.png"     >/dev/null
    done
    iconutil -c icns "$set" -o "$ICON_OUT"
}

build_icon

# ---- Build ---------------------------------------------------------------

echo "==> Building Swift package ($CONFIG)"
swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/$APP_NAME"
HOOK_BIN="$ROOT/.build/$CONFIG/tm-hook"
if [[ ! -x "$BIN" ]]; then
    echo "Error: built binary not found at $BIN" >&2
    exit 1
fi
if [[ ! -x "$HOOK_BIN" ]]; then
    echo "Error: tm-hook binary not found at $HOOK_BIN" >&2
    exit 1
fi

# Sparkle ships as an XCFramework via SPM. SPM unpacks it into .build/artifacts
# but does not embed it into the executable — we have to copy it ourselves.
SPARKLE_FW="$(find "$ROOT/.build/artifacts" -type d -name "Sparkle.framework" -path "*macos*" 2>/dev/null | head -n1)"
if [[ -z "$SPARKLE_FW" || ! -d "$SPARKLE_FW" ]]; then
    echo "Error: Sparkle.framework not found under .build/artifacts." >&2
    echo "       Run 'swift package resolve' to download it." >&2
    exit 1
fi

# ---- Assemble bundle ------------------------------------------------------

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$HOOK_BIN" "$APP/Contents/MacOS/tm-hook"

mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

ICON_PLIST_ENTRY=""
if [[ -f "$ICON_OUT" ]]; then
    cp "$ICON_OUT" "$APP/Contents/Resources/AppIcon.icns"
    ICON_PLIST_ENTRY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>"
fi

# Sparkle keys only land in the plist when a public key is provided. Dev
# builds without one still link against Sparkle (the framework is embedded)
# but the updater stays inert because there's no feed URL or pinned key.
SPARKLE_PLIST_ENTRY=""
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    SPARKLE_PLIST_ENTRY="    <key>SUFeedURL</key>
    <string>$SPARKLE_FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>SUAutomaticallyDownloadsUpdates</key>
    <false/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Tidsmaskinen reads the active Chrome tab URL to attribute browsing time to customers.</string>
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Tidsmaskinen detects when the microphone is in use (without recording audio) to identify VoIP calls for time attribution.</string>
$ICON_PLIST_ENTRY
$SPARKLE_PLIST_ENTRY
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

ENTITLEMENTS="$ROOT/Resources/Tidsmaskinen.entitlements"
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "Error: missing entitlements at $ENTITLEMENTS" >&2
    exit 1
fi

# ---- Sign -----------------------------------------------------------------

# Sign inside-out so each nested bundle's seal includes its own signature.
# --deep is deprecated and silently re-signs nested code with the outer
# identity, which trips notarization when nested binaries already have
# signatures with mismatched flags.
sign_bundle() {
    local target="$1"
    shift
    codesign --force --options runtime $TIMESTAMP_FLAG \
        --sign "$SIGN_IDENTITY" "$@" "$target" 2>&1 | sed 's/^/    /'
}

SPARKLE_INNER="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

echo "==> Signing Sparkle internals"
for xpc in "$SPARKLE_INNER/XPCServices"/*.xpc; do
    [[ -e "$xpc" ]] && sign_bundle "$xpc"
done
sign_bundle "$SPARKLE_INNER/Updater.app"
sign_bundle "$SPARKLE_INNER/Autoupdate"
sign_bundle "$APP/Contents/Frameworks/Sparkle.framework"

echo "==> Signing tm-hook"
sign_bundle "$APP/Contents/MacOS/tm-hook"

echo "==> Signing $APP_NAME.app as: $SIGN_IDENTITY"
sign_bundle "$APP" --entitlements "$ENTITLEMENTS"

echo "==> Verifying signature"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|Authority|Signature|Format)=' | sed 's/^/    /'

xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# ---- Notarize (optional) -------------------------------------------------

ZIP=""
if [[ "$NOTARIZE" == "1" ]]; then
    : "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required when NOTARIZE=1}"
    : "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required when NOTARIZE=1}"
    : "${APPLE_API_KEY_PATH:?APPLE_API_KEY_PATH is required when NOTARIZE=1}"

    mkdir -p "$ROOT/build"
    ZIP="$ROOT/build/$APP_NAME.zip"

    echo "==> Zipping for notarization submission"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

    echo "==> Submitting to notarytool (this can take several minutes)"
    xcrun notarytool submit "$ZIP" \
        --key "$APPLE_API_KEY_PATH" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_ISSUER_ID" \
        --wait

    echo "==> Stapling ticket to app"
    xcrun stapler staple "$APP"

    echo "==> Re-zipping stapled app"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "    Release artifact: $ZIP"
fi

echo
echo "✓ Built $APP_NAME.app"
echo
echo "  bundle id:    $BUNDLE_ID"
echo "  version:      $VERSION"
echo "  signed as:    $SIGN_IDENTITY"
echo
echo "Launch:  open $APP_NAME.app"
echo "Quit existing instance first if running (menu bar icon → Quit, or pkill -f $APP_NAME)."
