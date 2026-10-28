#!/bin/bash
# Builds the native iPad app, installs it on your iPad and opens it. Run it again before the install
# expires: 7 days with a free Apple account. The menu bar app shows when, and its Reinstall iPad App
# runs this script in Terminal.
#
# Needs full Xcode signed into your Apple ID, XcodeGen (brew install xcodegen), and the iPad paired
# with this Mac with Developer Mode on (iPad/README.md has the one-time setup). The team ID comes from
# your Apple Development certificate and the iPad is the first one paired; set DEVELOPMENT_TEAM or
# IPAD (an identifier from `xcrun devicectl list devices`) to choose.
set -euo pipefail
cd "$(dirname "$0")/../iPad"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"   # Homebrew, when run from the menu bar app

command -v xcodegen >/dev/null || { echo "Needs XcodeGen: brew install xcodegen"; exit 1; }

team="${DEVELOPMENT_TEAM:-$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | /usr/bin/openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F' = ' '/organizationalUnitName/ {print $2; exit}' || true)}"
if [ -z "$team" ]; then
    echo "No Apple Development certificate in your keychain. In Xcode, add your Apple ID (Settings →"
    echo "Accounts) and pick your Personal Team in any project's Signing & Capabilities once."
    exit 1
fi

devices=$(mktemp)
stash=$(mktemp -d)
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
# On any exit, profiles still set aside go back (see below).
trap 'mv "$stash"/* "$profiles/" 2>/dev/null; rm -rf "$devices" "$stash"' EXIT
xcrun devicectl list devices --json-output "$devices" >/dev/null
device="${IPAD:-$(/usr/bin/python3 - "$devices" <<'EOF'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hardware = d["properties"]["hardware"]
    if hardware.get("deviceType") == "iPad" and hardware.get("reality") == "physical":
        print(d["identifier"])
        break
EOF
)}"
if [ -z "$device" ]; then
    echo "No iPad is paired with this Mac. Plug it in, unlock it and tap Trust."
    exit 1
fi

build() {
    xcodebuild -project PortraitViewer.xcodeproj -scheme PortraitViewer -sdk iphoneos -derivedDataPath build \
        -allowProvisioningUpdates -quiet DEVELOPMENT_TEAM="$team" build
}

# Xcode reuses its cached profile until that expires, so reinstalling wouldn't move the date. With it
# set aside, -allowProvisioningUpdates fetches a new one, valid for another 7 days.
for profile in "$profiles"/*.mobileprovision; do
    [ -f "$profile" ] || continue
    id=$(security cms -D -i "$profile" 2>/dev/null | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || true)
    [[ "$id" == *.com.danielfung.PortraitDisplay.Viewer ]] && mv "$profile" "$stash/"
done

echo "Building…"
xcodegen -q
if build; then
    rm -f "$stash"/*   # replaced by the new profile
else
    # Fetching needs Xcode's Apple ID sign-in, which can lapse; the old profile still builds.
    echo "Couldn't get a new profile from Apple, so the expiry date won't move. If this keeps happening,"
    echo "sign in again in Xcode → Settings → Accounts. Building with the current profile…"
    mv "$stash"/* "$profiles/" 2>/dev/null || exit 1
    build
fi
app=build/Build/Products/Debug-iphoneos/PortraitViewer.app

echo "Installing…"
xcrun devicectl device install app --device "$device" "$app" >/dev/null
xcrun devicectl device process launch --device "$device" com.danielfung.PortraitDisplay.Viewer >/dev/null 2>&1 \
    || echo "Unlock the iPad and open Portrait Display."

expires=$(security cms -D -i "$app/embedded.mobileprovision" | plutil -extract ExpirationDate raw -o - -)
echo "Installed. This install stops opening at $expires (UTC)."
