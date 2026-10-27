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
  the encoder. It only encodes when the iPad has room (`StreamServer.freeSlots`); otherwise the newest
  frame waits. Skipping before encoding is free; skipping after costs a keyframe (that made video stutter). 0.3 s after the screen goes
  still it re-encodes the last frame once to sharpen it; keyframe requests also re-encode it.
- `VideoEncoder.swift`: VideoToolbox H.264 (High) or HEVC (Main, `--codec hevc`), no B-frames, real time,
  output as length-prefixed NALs + avcC / hvcC. Only a bitrate cap (`--bitrate`): both hardware encoders
  ignore `Quality`, and `MaxAllowedFrameQP` overrides the cap (and is ignored if changed mid-session).
  Keyframes only on request; `MaxKeyFrameInterval` is Int32.max because 0 measured a keyframe every ~2 s.
  `switchCodec` swaps the session at the next frame (a keyframe with a new config).
  HEVC vs H.264, measured on scrolling text at 2048×2668: 4.1 vs 6.6 Mbit/s at the same PSNR (needs
  `PrioritizeEncodingSpeedOverQuality` off, else HEVC is 4 dB worse), but the settled still frame is
  43.6 vs 46.4 dB. So H.264 stays the default.
- Codec negotiation: the viewer sends `hello <token> hevc` if `VideoDecoder.isConfigSupported` says so.
  With `--codec hevc` the server uses HEVC only while every connected iPad can decode it. If an HEVC
  config fails before any frame decodes, the viewer reconnects without `hevc`.
- `H264NoReorder.swift`: patches the SPS in the avcC to say `max_num_reorder_frames = 0`. Without it,
  decoders hold back up to 7 frames (seen in Chrome), so the last change on a still screen never shows.
- `Certificates.swift`: WebCodecs needs a secure context, so the page is HTTPS. A local CA in
  `~/.portraitdisplay/` (name-constrained to private IPs) is installed on the iPad once; a server cert
  for the current IPs is issued with `/usr/bin/openssl` each run and loaded in memory only.
- `StreamServer.swift`: Network.framework. HTTP on `--port` (default 8080) serves the setup page and
  the CA. HTTPS on port+1 serves the viewer page and manifest. Secure WebSocket on port+2: client sends
  `hello <token>`, server sends codec config (JSON text) before keyframes and frames as binary
  (1-byte keyframe flag + AVCC). Client sends `ack` per frame, `key` after a decoder error, `d <ms>`
  (decode time) and input messages (`c`/`p`/`s …`). At most 4 unacked frames per iPad.
  Every 2 s while frames flow, a stats line (capture, encode, sent/skipped, Mbit/s, ack round trip,
  iPad decode) is printed and shown on the overlay. Use it before guessing at performance.
  Its "encoded in N ms" is almost all VideoToolbox: everything after the encoder's callback (copy,
  server queue, send) measured 0.1 ms. The encoder itself takes ~10 ms at 2048×2668, but the same
  build measured 26–43 ms in some runs. Not explained by App Nap, colour tags, capture buffers,
  or GPU / memory load (all tested); cause outside the process. `EnableLowLatencyRateControl` is slower (12.5 ms).
- `SetupPage.swift` / `ViewerPage.swift`: the iPad pages, raw Swift strings with `__PLACEHOLDER__`s.
  The setup page forwards to HTTPS once the cert is trusted. The viewer decodes with `VideoDecoder`
  and draws the newest frame on a canvas (reconnect, wake lock, overlay showing the iPad's size).
- `InputInjector.swift`: touch / Pencil messages → CGEvent mouse, tablet-pressure and phased scroll
  events on the virtual display (needs Accessibility permission). Message format is in its header.
  The viewer page does the gesture recognition: Pencil/mouse = pointer, finger tap = click,
  finger drag = scroll with JS-side momentum, two-finger tap = right-click, three-finger tap = overlay.
  The native app (`iPad/PortraitViewer/TouchInput.swift`) adds `g z`/`g r` (pinch / rotate, posted as
  private gesture CGEvents: type 29, field 110 = HID type 8 zoom / 5 rotation, 132 = phase, 113 / 114 =
  value; verified to reach an NSView's magnify / rotate) and `w` (three-finger swipe → Control-arrow).
  It snaps a tap near the previous one to the same spot, since the Mac's double-click check is 24 pt.
  No event type tried produced smart zoom or a page swipe.
- `Config.swift`: CLI options, token saved in `~/.portraitdisplay-token`, local IP listing.
- `DisplayController.swift`: owns the virtual display and capture. With `--on-demand` it creates them
  when the first iPad connects and removes them `--linger` seconds (15; the app passes 120) after the last one leaves; capture
  is stopped before the display goes. Each new display gets a new ID (the injector follows it);
  macOS restores its Retina mode and position by vendor/product/serial. ScreenCaptureKit stops with
  "Failed to find any displays" whenever the Mac's screens turn off (idle or lid), so a lost capture
  waits for screens-on, system sleep stops it and wake restarts it (2 s, with retries). While an iPad
  is connected it holds a PreventUserIdleDisplaySleep assertion, so idling doesn't freeze the iPad.
- `main.swift`: SIGINT (Ctrl+C, or the app's Stop) is a dispatch source installed right after parsing, so a
  Stop during setup still exits cleanly. `Config.parse` rejects streams above H.264's 139,264 macroblocks:
  the encoder accepts the session but fails every frame. Wires it together, then runs `NSApplication`
  (policy `.prohibited`), not `dispatchMain()`:
  without an AppKit run loop the process never sees display changes, and a re-created display has no
  modes. With `--status-lines` it also prints `@key value` lines (`Status` in `Config.swift`) and exits
  when its parent process does.
- `Sources/PortraitMenu/`: the menu bar app. It runs PortraitHost (`Contents/Helpers`) as a child
  process with `--status-lines` and stops it with SIGINT, so a crash can never leave the display behind.
  `Settings.swift` maps the saved settings (same ranges as `Config.parse`) to host options, then appends
  the advanced `hostArguments` default. `SettingsWindow.swift` is a SwiftUI form that saves on edit and
  offers Restart Now when they differ from the running host's `runningArguments`. No `@State`: the
  Command Line Tools' Swift lacks SwiftUI's macro plugin. Number fields are an `NSTextField` that commits on
  end of editing: SwiftUI's TextField writes on every keystroke here, so clamping it mangled typed values.
  A main menu is installed (never shown) only so Cmd-C/V/A/W work in that window. The menu updates its status and stats lines in
  place while open and rebuilds only when its items change. Log: `~/Library/Logs/PortraitDisplay.log`.
  The host lives in `Contents/Helpers`: from `Contents/MacOS` it registered as a second app with the same
  bundle ID.
- `scripts/make-icons.sh` draws the icon (`scripts/make-icon.swift`) into the iPad asset catalog and
  `Resources/AppIcon.icns`, which make-app.sh copies into the bundle.
- `scripts/make-app.sh`: builds `Portrait Display.app` into `~/Applications`, signed with a self-signed
  certificate in its own keychain in `~/.portraitdisplay/signing`. TCC keys permissions on that certificate
  (designated requirement = identifier + leaf hash), so they survive rebuilds; ad-hoc signing would not.
  macOS attributes the child's permission requests to the app.

## Build / run
```
swift build -c release
swift run -c release PortraitHost   # defaults to 1024×1334 pt @ 60 fps (iPad Pro 12.9" Home Screen app)
scripts/make-app.sh                 # menu bar app → ~/Applications/Portrait Display.app
```
Needs Screen & System Audio Recording permission, and Accessibility for touch input, for whichever
terminal app runs it. macOS 15+.

## Ideas not done yet
- Native iPad viewer: done (`iPad/`, `USBMux.swift`, `ViewerLink.swift`, `DirectWiFi.swift`; the host
  emits `@links USB|direct Wi-Fi|Wi-Fi` for the menu). Direct Wi-Fi: Bonjour `_portraitdisplay._tcp`
  with `includePeerToPeer`, TLS 1.2 PSK with a key the Mac sends over USB
  (`~/.portraitdisplay/direct-wifi.key`, iPad Keychain); the browser requires a Wi-Fi interface and
  blocks en0 so it takes awdl0, and waits while a USB viewer is connected. New connections can sit in
  `.waiting` briefly before the peer-to-peer link is up, so it gives them 10 s. Design in `docs/native-viewer-design.md`, feasibility test in `Spike/link/`.
  Measured 2026-10-27: USB 0.31 ms median / 0.94 ms p99, direct Wi-Fi 5.2 ms / 143–268 ms, router
  12.7 ms / 212 ms. Bonjour also finds the iPad over `anri0`, an IPv6 network Xcode runs over the
  cable, so the Wi-Fi test requires a Wi-Fi interface and blocks en0.
