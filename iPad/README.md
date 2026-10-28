# Portrait Display for iPad

A native viewer for the Mac's "Portrait iPad" display over the USB cable. The Mac's host finds the
app through usbmuxd (the channel Xcode and Finder use) and connects to it on loopback port 20809;
frames are decoded in hardware and shown with `AVSampleBufferDisplayLayer`. No Safari, certificate
or network is involved. Design and measurements: `docs/native-viewer-design.md`.

Status: video, touch, Pencil and trackpad-style gestures (double tap, pinch, rotate, three-finger
swipes) work, over the cable or, after one USB connection to pair, over direct peer-to-peer Wi-Fi.
The main README lists the gestures. The app tells the Mac its screen size, so the display can match
it, and when its install expires, which the Mac's menu shows. Paired Macs lists the Macs it holds a
key for (one per Mac) and forgets one.

## Build and install

It needs full Xcode, signed into your Apple ID (a free account works; installs then last 7 days),
XcodeGen (`brew install xcodegen`), an iPad with Developer Mode on, and the iPad plugged in and
trusted. Pick your Personal Team once in Xcode's Signing & Capabilities for any project. Then:

```bash
scripts/install-ipad.sh
```

It reads your team ID from your Apple Development certificate, builds, installs on the first paired
iPad and opens the app. Run it again before the 7 days are up (the Mac's menu has Reinstall iPad App
for this). Xcode keeps using its cached provisioning profile until that expires, so reinstalling alone
wouldn't move the date; the script sets the cached one aside so Xcode fetches a new one. If Xcode can't
reach your Apple ID, it builds with the old profile and says the date didn't move: sign in again in
Xcode → Settings → Accounts.

By hand, with your team ID:

```bash
cd iPad && xcodegen
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PortraitViewer.xcodeproj \
  -scheme PortraitViewer -sdk iphoneos -derivedDataPath build -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=XXXXXXXXXX build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app \
  --device <iPad identifier> build/Build/Products/Debug-iphoneos/PortraitViewer.app
```

The first time, trust your Apple ID on the iPad in Settings → General → VPN & Device Management.
Then start Portrait Display on the Mac and open the app on the iPad with the cable connected.
