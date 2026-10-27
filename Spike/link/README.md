# Link feasibility test

Before building the native iPad viewer in `docs/native-viewer-design.md`, this checks whether the
Mac can reach an iPad app over the USB cable (usbmuxd) and over direct peer-to-peer Wi-Fi, and how
fast each is compared with Wi-Fi through the router. A link passes if the median round trip is
under 2 ms and the 99th percentile under 5 ms.

`EchoApp/` is an iPad app that echoes every byte on two listeners: loopback port 20808 for USB, and
a Bonjour service (`_portraitecho._tcp`) with peer-to-peer allowed for Wi-Fi. `rtt.swift` is the Mac
side. It connects over the chosen link, then times 1,000 round trips of 64 bytes (after 10 unmeasured
warm-up ones) and 20 of 300 KB, about the size of a keyframe.

Results from the first run, on 2026-10-27, are in `docs/native-viewer-design.md`: USB passed (median
0.31 ms, 99th percentile 0.94 ms), direct Wi-Fi had a 5.2 ms median but a 143 to 268 ms 99th
percentile, and the router path measured 12.7 ms and 212 ms.

Keep the echo app on screen while testing. iPadOS suspends it in the background, and its listeners
are restarted only when it comes back.

## One-time setup

1. Plug the iPad into the Mac with a USB-C cable that carries data, unlock it, and tap Trust.
2. On the iPad, turn on Settings → Privacy & Security → Developer Mode. The iPad restarts.
3. In Xcode, open Settings → Accounts, click + and sign in with your Apple ID. A free account is
   enough, but installs then last 7 days.
4. Note your team ID. After the first signed build, `security find-identity -v -p codesigning` shows
   it as `Apple Development: … (XXXXXXXXXX)`; Xcode's Accounts pane also lists it under the team.

## Run

```bash
cd Spike/link/EchoApp && xcodegen
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project EchoApp.xcodeproj \
  -scheme EchoApp -sdk iphoneos -derivedDataPath build -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=XXXXXXXXXX build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app \
  --device <iPad identifier> build/Build/Products/Debug-iphoneos/EchoApp.app
```

A free-account app has to be trusted once before it opens: Settings → General → VPN & Device
Management → your Apple ID. Then open Link Echo on the iPad (allow Local Network access when it
asks) and run these from the repo root, one at a time:

```bash
swift Spike/link/rtt.swift                # USB cable
swift Spike/link/rtt.swift --wifi         # direct Wi-Fi; the Mac's router Wi-Fi is blocked for this connection
swift Spike/link/rtt.swift --wifi-router  # Wi-Fi through the router, for comparison
```

The Wi-Fi modes need Local Network permission for the terminal app on the Mac too; macOS asks the
first time.
