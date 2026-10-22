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
- `Capturer.swift`: ScreenCaptureKit captures that display (changed frames only, 420v YUV) and feeds
  the encoder. While the encoder is busy, only the newest frame is kept. 0.3 s after the screen goes
  still it re-encodes the last frame once to sharpen it; keyframe requests also re-encode it.
- `VideoEncoder.swift`: VideoToolbox H.264 (High, no B-frames, real time), output as AVCC + avcC.
  Only a bitrate cap (`--bitrate`): the hardware H.264 encoder ignores `Quality`.
- `H264NoReorder.swift`: patches the SPS in the avcC to say `max_num_reorder_frames = 0`. Without it,
  decoders hold back up to 7 frames (seen in Chrome), so the last change on a still screen never shows.
- `Certificates.swift`: WebCodecs needs a secure context, so the page is HTTPS. A local CA in
  `~/.portraitdisplay/` (name-constrained to private IPs) is installed on the iPad once; a server cert
  for the current IPs is issued with `/usr/bin/openssl` each run and loaded in memory only.
- `StreamServer.swift`: Network.framework. HTTP on `--port` (default 8080) serves the setup page and
  the CA. HTTPS on port+1 serves the viewer page and manifest. Secure WebSocket on port+2: client sends
  `hello <token>`, server sends codec config (JSON text) before keyframes and frames as binary
  (1-byte keyframe flag + AVCC). Client sends `ack` per frame, `key` after a decoder error, and input messages (`c`/`p`/`s …`). More
  than 4 unacked frames → skip until the next keyframe.
- `SetupPage.swift` / `ViewerPage.swift`: the iPad pages, raw Swift strings with `__PLACEHOLDER__`s.
  The setup page forwards to HTTPS once the cert is trusted. The viewer decodes with `VideoDecoder`
  and draws the newest frame on a canvas (reconnect, wake lock, overlay showing the iPad's size).
- `InputInjector.swift`: touch / Pencil messages → CGEvent mouse, tablet-pressure and phased scroll
  events on the virtual display (needs Accessibility permission). Message format is in its header.
  The viewer page does the gesture recognition: Pencil/mouse = pointer, finger tap = click,
  finger drag = scroll with JS-side momentum, two-finger tap = right-click, three-finger tap = overlay.
- `Config.swift`: CLI options, token saved in `~/.portraitdisplay-token`, local IP listing.
- `main.swift`: wires it together, then `dispatchMain()`.

## Build / run
```
swift build -c release
swift run -c release PortraitHost   # defaults to 1024×1334 pt @ 60 fps (iPad Pro 12.9" Home Screen app)
```
Needs Screen & System Audio Recording permission, and Accessibility for touch input, for whichever
terminal app runs it. macOS 15+.

## Ideas not done yet
- HEVC instead of H.264 (smaller again; check Safari's WebCodecs HEVC support first).
- Menu bar app wrapper instead of a Terminal command.
- USB connection instead of Wi-Fi.
