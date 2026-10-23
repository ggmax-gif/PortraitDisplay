# USB feasibility test

Before building the USB connection in `docs/usb-design.md`, this checks whether the Mac can reach an
iPad app's port through the cable via usbmuxd, and how fast. It passes if the median round trip is
under 2 ms and the 99th percentile under 5 ms.

`EchoApp/` is an iPad app that listens on loopback port 20808 and echoes every byte. `rtt.swift` is
the Mac side: it waits for the iPad on usbmuxd, connects to port 20808, and times 1,000 round trips
of 64 bytes and 20 of 300 KB (about the size of a keyframe).

## One-time setup

1. Plug the iPad into the Mac with a USB-C cable that carries data, unlock it, and tap Trust.
2. On the iPad, turn on Settings → Privacy & Security → Developer Mode. The iPad restarts.
3. In Xcode, open Settings → Accounts, click + and sign in with your Apple ID. A free account is
   enough, but installs then last 7 days.
4. Note your team ID. After the first signed build, `security find-identity -v -p codesigning` shows
   it as `Apple Development: … (XXXXXXXXXX)`; Xcode's Accounts pane also lists it under the team.

## Run

```bash
cd Spike/usb/EchoApp && xcodegen
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project EchoApp.xcodeproj \
  -scheme EchoApp -sdk iphoneos -derivedDataPath build -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=XXXXXXXXXX build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app \
  --device <iPad identifier> build/Build/Products/Debug-iphoneos/EchoApp.app
```

A free-account app has to be trusted once before it opens: Settings → General → VPN & Device
Management → your Apple ID. Then open USB Echo on the iPad and run this from the repo root:

```bash
swift Spike/usb/rtt.swift
```
