# Portrait Display for iPad

A native viewer for the Mac's "Portrait iPad" display over the USB cable. The Mac's host finds the
app through usbmuxd (the channel Xcode and Finder use) and connects to it on loopback port 20809;
frames are decoded in hardware and shown with `AVSampleBufferDisplayLayer`. No Safari, certificate
or network is involved. Design and measurements: `docs/native-viewer-design.md`.

Status: video, touch, Pencil and trackpad-style gestures (double tap, pinch, rotate, three-finger
swipes) work. The main README lists the gestures.

## Build and install

It needs full Xcode, signed into your Apple ID (a free account works; installs then last 7 days),
an iPad with Developer Mode on, and the iPad plugged in and trusted. Pick your Personal Team once in
Xcode's Signing & Capabilities for any project, then use its team ID below.

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
