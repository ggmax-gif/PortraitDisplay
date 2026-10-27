#!/bin/bash
# Regenerates the app icons from scripts/make-icon.swift: the iPad app's asset catalog image and the
# Mac app's AppIcon.icns (which scripts/make-app.sh copies into the bundle).
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swiftc -O scripts/make-icon.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/icon-1024.png"
# Exactly 1024×1024 pixels, whatever the screen's scale.
sips -z 1024 1024 "$TMP/icon-1024.png" --out "$TMP/icon-1024.png" >/dev/null

ASSET=iPad/PortraitViewer/Assets.xcassets/AppIcon.appiconset
mkdir -p "$ASSET"
cp "$TMP/icon-1024.png" "$ASSET/icon-1024.png"
cat > "$ASSET/Contents.json" <<'EOF'
{
  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF
cat > iPad/PortraitViewer/Assets.xcassets/Contents.json <<'EOF'
{ "info" : { "author" : "xcode", "version" : 1 } }
EOF

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote $ASSET/icon-1024.png and Resources/AppIcon.icns"
