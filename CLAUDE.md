# PortraitDisplay

Personal tool. Turns an iPad into a **portrait** second screen for a MacBook (Apple silicon, recent
macOS) through Safari over Wi-Fi. It replaces Sidecar, which on this Mac is stuck in landscape.
BetterDisplay's stream to Sidecar only showed black, which is why this was written.
Not for the App Store, because it uses a private API.

## How it works
- `Sources/CGVirtualDisplayPrivate/include/CGVirtualDisplayPrivate.h`: declarations for Apple's
  private `CGVirtualDisplay*` classes (in CoreGraphics), with NS_SWIFT_NAME annotations.
- `VirtualDisplay.swift`: creates the portrait virtual monitor "Portrait iPad", HiDPI by default.
  Picks the "looks like W×H" Retina mode with the public `CGDisplaySetDisplayMode`.
- `Capturer.swift`: ScreenCaptureKit captures that display (changed frames only) and encodes JPEG
  with CIContext. While the encoder is busy, only the newest frame is kept.
- `StreamServer.swift`: Network.framework. HTTP on `--port` (default 8080) serves the page and
  manifest. The WebSocket on port+1 sends frames. Pull-based: the client sends `hello <token>`,
  then `next` after each frame it draws.
- `ViewerPage.swift`: the iPad web page (canvas, reconnect, wake lock, overlay showing the iPad's
  size). It is a raw Swift string with `__TOKEN__` / `__WS_PORT__` / `__NAME__` placeholders.
- `Config.swift`: CLI options, token saved in `~/.portraitdisplay-token`, local IP listing.
- `main.swift`: wires it together, then `dispatchMain()`.

## Build / run
```
swift build -c release
swift run -c release PortraitHost --width 820 --height 1180   # iPad size in points, shown on the page
```
Needs Screen & System Audio Recording permission for whichever terminal app runs it.

## Ideas not done yet
- H.264/HEVC via VideoToolbox + WebCodecs on the iPad instead of JPEG (less bandwidth, smoother).
- Touch / Apple Pencil input from the iPad back to the Mac.
- Menu bar app wrapper instead of a Terminal command.
- USB connection instead of Wi-Fi.
