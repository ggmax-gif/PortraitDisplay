#!/bin/bash
# Builds Portrait Display.app (menu bar app + PortraitHost), signs it and installs it in ~/Applications.
#
# It is signed with a self-signed certificate kept in its own keychain in ~/.portraitdisplay/signing
# (the login keychain is not touched). macOS ties Screen Recording and Accessibility permission to
# that certificate, so they survive rebuilds. Ad-hoc signing would change the identity every build.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=com.danielfung.PortraitDisplay
APP_NAME="Portrait Display"
INSTALL_DIR="$HOME/Applications"
SIGN_DIR="$HOME/.portraitdisplay/signing"
KEYCHAIN="$SIGN_DIR/signing.keychain-db"
IDENTITY="PortraitDisplay Local Signing"
OPENSSL=/usr/bin/openssl   # macOS's LibreSSL; its PKCS#12 output is what `security import` reads

swift build -c release
BIN=$(swift build -c release --show-bin-path)

APP="build/$APP_NAME.app"
rm -rf "$APP"
# The host goes in Helpers, not MacOS: it runs an AppKit run loop, and from Contents/MacOS macOS
# would register it as a second "Portrait Display" (same bundle ID), so a Quit could reach it instead.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp "$BIN/PortraitMenu" "$APP/Contents/MacOS/PortraitDisplay"
cp "$BIN/PortraitHost" "$APP/Contents/Helpers/PortraitHost"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>PortraitDisplay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# One-time: create the signing certificate and its keychain.
if [ ! -f "$KEYCHAIN" ]; then
    echo "Creating signing certificate in $SIGN_DIR"
    mkdir -p "$SIGN_DIR"
    chmod 700 "$SIGN_DIR"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    "$OPENSSL" req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -config "$TMP/cert.cnf" -extensions ext -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    "$OPENSSL" pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/identity.p12" -passout pass:portraitdisplay
    # Empty password: the keychain only guards this local, self-signed key.
    security create-keychain -p "" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"   # no auto-lock
    security import "$TMP/identity.p12" -k "$KEYCHAIN" -P portraitdisplay -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null
fi
security unlock-keychain -p "" "$KEYCHAIN"

# Helper first, then the bundle (whose signature covers the helper).
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --identifier "$BUNDLE_ID.host" \
    "$APP/Contents/Helpers/PortraitHost"
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

# Replace the installed copy (quitting it first stops any stream it is running).
pkill -x PortraitDisplay && sleep 1 || true
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"
echo "Installed $INSTALL_DIR/$APP_NAME.app"
echo "Open it with:  open \"$INSTALL_DIR/$APP_NAME.app\""
