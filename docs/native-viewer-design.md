# Native iPad viewer: design

Status: built and in use. USB (`iPad/`, `Sources/PortraitHost/USBMux.swift`, `ViewerLink.swift`)
carries video, touch, Pencil and trackpad gestures, with reconnects on unplugging and backgrounding.
Direct Wi-Fi (`DirectWiFi.swift`) takes over when the cable is unplugged and hands back when it's
plugged in; in use it measured 7 to 10 ms typical frame round trips, with busy-moment spikes to about
200 ms. Pairing is over USB rather than the 4-digit code planned below: the Mac sends the app a
256-bit key, and Wi-Fi uses TLS 1.2 with it as a pre-shared key. The feasibility test (`Spike/link/`) ran on 2026-10-27;
results below. Written 2026-10-23, revised 2026-10-27.

## Results

Measured on 2026-10-27 between a MacBook (Apple silicon, macOS 27.2) and an iPad Pro 12.9" (4th
generation, iPadOS 27.2), with the Mac also connected to a managed 802.1X Wi-Fi network. Each row is
1,000 round trips of 64 bytes after a 10-ping warm-up, plus 20 round trips of 300 KB, about one
keyframe.

| Path | Median | 99th percentile | Worst | 300 KB throughput, each way |
|---|---|---|---|---|
| USB cable, usbmuxd | 0.31 ms | 0.94 ms | 1.24 ms | 352 Mbit/s |
| USB cable, Bonjour over anri0 (see below) | 0.37 ms | 0.72 ms | 1.06 ms | 317 Mbit/s |
| Direct Wi-Fi, awdl0 (two runs) | 5.24 and 5.27 ms | 143 and 268 ms | 279 and 282 ms | 368 and 349 Mbit/s |
| Wi-Fi through the router, en0 | 12.73 ms | 212 ms | 449 ms | 48 Mbit/s |

What this means for the design:

- USB passes easily, at about 40 times lower median latency than the router and with no tail, so
  it's the main path. The router row matches what the stream's stats line has shown all along
  (12 to 160 ms, spikes to 440 ms), so the test measures what users feel.
- Direct Wi-Fi halves the router's median latency and has seven times its throughput, but its
  99th percentile is still 143 to 268 ms. The likely cause is that the Mac's radio is also
  associated with the router, so it divides its time between the router's channel and the
  peer-to-peer one, and some packets wait for the switch. Moving frames to UDP wouldn't help with
  that. Direct Wi-Fi stays as the cable-free option, especially where the router blocks devices
  from reaching each other.
- A surprise: while the iPad is paired with Xcode, the cable also carries an ordinary IPv6
  network (`anri0` on the Mac, link-local addresses only), and Bonjour found the app over it before
  trying Wi-Fi. The direct Wi-Fi test therefore has to require a Wi-Fi interface and block the
  router's one. It might also let Safari reach the Mac over the cable without the app, but only
  while Xcode's device tunnel is up, so it isn't a path to rely on.
- The echo app's Bonjour listener died with `DefunctConnection` after the app had been in the
  background, and the USB one stopped too. The real app has to restart its listeners whenever it
  returns to the foreground, as the echo app now does.

## Goal

Replace the Safari page with a small native iPad app, so the stream can use two links the web page
can't:

- a USB-C cable, through usbmuxd (the channel Xcode and Finder use), and
- direct Wi-Fi between the two devices, the peer-to-peer link AirDrop uses (and, judging by its
  requirements, Sidecar), so the stream never passes through the router.

Both remove the dependence on the local network (managed 802.1X networks, such as student housing
ones, may not let devices reach each other at all), and both should cut latency.

The stats line shows what the router path costs today, on my Mac: 0.0 to 1.4 Mbit/s used, round
trips of 12 to 160 ms, and spikes to 440 ms when a stream starts. Bandwidth isn't the problem;
latency is. The target for both new links is a round trip under 5 ms, which is a goal and not yet a
measurement.

## Why it needs a native app

Safari can only reach the Mac over IP through the router. It can't open a peer-to-peer Wi-Fi
connection or listen on a port, and over a plain USB cable IP needs Personal Hotspot over USB, which
needs a carrier plan (my iPad has none).

A native app can do both with public API:

- Over USB, usbmuxd lets a process on the Mac open a TCP connection to a port an app on the iPad is
  listening on; the PeerTalk library is built on this. Checked on my Mac: `/var/run/usbmuxd`
  exists, has mode `srw-rw-rw-` (so no root is needed), and answered a `ListDevices` request with
  protocol version 1.
- Over direct Wi-Fi, Network.framework uses the peer-to-peer link when a listener or browser sets
  `includePeerToPeer`. The app advertises a Bonjour service; the Mac browses for it and connects.

In both cases the Mac connects to the iPad, so the Mac side needs only one connection path once it
has found the device. It doesn't matter which link the bytes take.

Alternatives considered:

| Option | Why not, for now |
|---|---|
| USB Personal Hotspot | Needs a carrier plan. |
| USB-C Ethernet adapters and a cable | Works with today's code, but it takes two adapters rather than one cable. |
| A phone hotspot both devices join | Works now with no code, but it's still a router path. |

## Architecture

```
Mac                                                    iPad
PortraitHost                                           PortraitViewer (new app)
  Capturer → VideoEncoder → StreamServer                 listeners: loopback :20808 (USB),
                              ├─ Safari viewers (WebSocket, unchanged)          Bonjour, peer-to-peer (Wi-Fi)
                              └─ native viewers ── usbmuxd or Bonjour ──▶ decode → AVSampleBufferDisplayLayer
  InputInjector ◀──────── c / p / s messages ──────────────── touch & Pencil gestures
```

Once a connection is open, the existing protocol runs over it unchanged.

### Wire format

The messages are the ones the WebSocket carries today, framed for a plain byte stream:

```
[u32 big-endian length of the rest] [u8 kind: 0 = text, 1 = binary] [payload]
```

- Mac to iPad: the codec config (JSON text, as now), frames (binary: a 1-byte keyframe flag, then
  AVCC or HVCC) and stats (JSON text).
- iPad to Mac: `hello native [hevc]`, `ack`, `key`, `d <ms>`, and the input messages `c`, `p` and
  `s`, unchanged (their format is in the header of `InputInjector.swift`).
- Over USB there's no token: it already needs physical access and a trusted pairing. Over Wi-Fi the
  app shows a 4-digit code the first time a Mac connects, and remembers the Mac after that, so a
  stranger nearby can't take over the screen. (Pairing is the one piece the web page doesn't need,
  because it uses the token in its link.)

### Mac side (PortraitHost)

1. `USBMux.swift` is a client for `/var/run/usbmuxd`. Each message is a 16-byte header (length,
   version 1, type 8 for plist, tag) followed by an XML plist. `Listen` delivers `Attached` and
   `Detached` events with a `DeviceID`. `Connect` (with `DeviceID` and `PortNumber`) turns the socket
   into a raw TCP tunnel to the iPad's port once the reply says `Result 0`. `PortNumber` is expected
   in network byte order inside the plist integer, as libimobiledevice sends it; the feasibility
   test confirms this.
2. `PeerBrowser.swift` browses for the app's Bonjour service with `includePeerToPeer`, and blocks
   the router's Wi-Fi interface for that connection so it really takes the direct link.
3. An attach loop: whenever usbmuxd reports the iPad or the browser finds it, it connects (retrying
   every second while the app isn't open yet). If both are available, USB wins.
4. `Viewer` in `StreamServer` currently owns an `NWConnection` with WebSocket framing. A small
   `ViewerLink` interface (send text, send binary, receive a message, close) gets a WebSocket
   implementation and a framed-stream one, used for both new links. Flow control (4 frames in
   flight), keyframe handling, codec choice, stats and the viewer count stay shared, so the
   on-demand display, HEVC negotiation, sleep handling and the menu bar app all work unchanged.
5. A `--no-native` option, and a menu line saying how the iPad is connected (USB, direct Wi-Fi or
   browser).

### iPad side (new app in an `iPad/` folder)

1. Two `NWListener`s, as in the feasibility test: TCP port 20808 bound to loopback (where usbmuxd
   delivers the USB connection), and a Bonjour service with `includePeerToPeer`. One connection at a
   time; a new one replaces the old.
2. Decoding and display: the app builds a `CMVideoFormatDescription` from the avcC or hvcC in the
   codec config, wraps each frame in a `CMSampleBuffer` marked `DisplayImmediately`, and enqueues it
   on an `AVSampleBufferDisplayLayer`, which decodes in hardware. If that layer holds frames back, it
   decodes with `VTDecompressionSession` and shows the pixel buffers instead. It sends `ack` per
   frame and `d <ms>` for decode time, as the web page does.
3. Input follows the gesture rules in `ViewerPage.swift`. The Pencil or a mouse is the pointer, with
   pressure and tilt from `UITouch.force`, `altitudeAngle` and `azimuthAngle`. A finger tap is a
   click, a finger drag scrolls with momentum, a two-finger tap is a right-click, and a three-finger
   tap shows the overlay.
4. The app runs full screen with the status bar hidden, keeps the screen on while connected
   (`isIdleTimerDisabled`), shows the same overlay as the web page (including the size to enter in
   Settings), and says "Start Portrait Display on the Mac" when idle.

The native app needs no certificate and no WebCodecs, so the certificate install step goes away
for it. The Safari page keeps working for anyone who doesn't install the app.

## Later: UDP

Both new links start on TCP, like the WebSocket. On a clean USB link that makes no difference. On
Wi-Fi, TCP holds every later frame back while one lost packet is resent, which is the likely cause
of today's 440 ms spikes. If the direct link still shows spikes, the next step is QUIC datagrams
(Network.framework supports them), sending frames unreliably and asking for a keyframe after a loss,
as the flow control already does when an iPad falls behind.

## Building and signing

- It needs full Xcode. Command-line builds set `DEVELOPER_DIR` to Xcode, so the default Command
  Line Tools stay as they are for `swift build`.
- With a free Apple ID, Xcode installs the app for 7 days; after that it won't open until it's
  rebuilt and reinstalled. A paid developer account (USD 99 a year) makes an install last a year.
  When the iPad is plugged in, the menu bar app could reinstall it automatically before it expires.
- The iPad has to trust the Mac ("Trust This Computer"), and Developer Mode has to be on (Settings →
  Privacy & Security) to run a self-built app. The app and the Mac both ask once for Local Network
  permission, which Bonjour needs.
- The cable has to carry data. A charge-only cable shows no device.

## Risks

| Risk | How we'd notice | Fallback |
|---|---|---|
| usbmuxd `Connect` to an app's port doesn't work on iPadOS 27 (the protocol is private) | Ruled out on 2026-10-27: it works, at 0.31 ms | |
| Direct Wi-Fi's long tail makes it feel no better than the router | Pencil and scrolling over `awdl0` still stutter | USB, or the router path |
| `AVSampleBufferDisplayLayer` adds a frame or more of delay | Visible delay, or a high decode time | `VTDecompressionSession` with Metal |
| Reinstalling the free install every 7 days gets tedious | The app stops opening | Automatic reinstall, a paid account, or the Safari page |
| The app only runs in the foreground | Switching apps on the iPad drops the stream | The same as the web page today; the on-demand display stays for the grace period |

## Plan

1. Feasibility test: done on 2026-10-27 (results above). USB passed; direct Wi-Fi didn't meet the
   5 ms 99th-percentile target but beats the router.
2. The Mac side (`USBMux.swift`, `PeerBrowser.swift`, `ViewerLink` and the attach loop): about a day.
3. The iPad app (decoding, display, input, overlay, Wi-Fi pairing): two to three days.
4. Compare latency and how the Pencil feels across the three paths, using the stats line.

The time estimates are guesses rather than measurements.

## Open questions

- How much of direct Wi-Fi's tail goes away when the Mac isn't also on a router network? Worth one
  run with the Mac's Wi-Fi disconnected from the access point.
- Should the app tell the Mac its screen size, so the virtual display can size itself instead of
  using the size in Settings?
