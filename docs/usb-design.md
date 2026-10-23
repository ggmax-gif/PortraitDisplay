# USB connection: design

Status: the feasibility test is written (`Spike/usb/`) but hasn't been run on an iPad yet. Nothing
below is built. Written 2026-10-23.

## Goal

Stream to the iPad over one USB-C cable instead of Wi-Fi. That removes any dependence on the network
(managed 802.1X networks, such as student housing ones, may not let devices reach each other at all)
and should give lower, steadier latency. No internet connection is involved; the cable is only a
data link.

The stats line shows what Wi-Fi costs today, on my Mac: 0.0 to 1.4 Mbit/s used, round trips of 12
to 160 ms, and spikes to 440 ms when a stream starts. Bandwidth isn't the problem; latency and the
network are. The target over USB is a round trip under 5 ms, which is a goal and not yet a
measurement.

## Why it needs a native iPad app

Safari can only reach the Mac over IP. Over a plain USB cable, IP needs Personal Hotspot over USB,
which needs a carrier plan, and my iPad has none. The only other data channel over the cable is
usbmuxd, which Xcode and Finder use. It lets a process on the Mac open a TCP connection to a port
that an app on the iPad is listening on; the PeerTalk library is built on this. Safari can't listen
on a port, so the iPad side has to be an app.

Checked on my Mac: `/var/run/usbmuxd` exists, has mode `srw-rw-rw-` (so no root is needed), and
answered a `ListDevices` request with protocol version 1.

Alternatives considered:

| Option | Why not, for now |
|---|---|
| USB Personal Hotspot | Needs a carrier plan. |
| USB-C Ethernet adapters and a cable | Works with today's code, either with manual IPs or after a small change to allow 169.254.x link-local addresses. But it takes two adapters rather than one cable. It's still the fallback if the feasibility test fails. |
| A phone hotspot both devices join | Works now with no code, but the latency is still Wi-Fi's. |

## Architecture

```
Mac                                                    iPad
PortraitHost                                           PortraitViewer (new app)
  Capturer → VideoEncoder → StreamServer                 NWListener on port 20808
                              ├─ Wi-Fi viewers (WebSocket, unchanged)
                              └─ USB viewers ── usbmuxd ── cable ──▶ decode → AVSampleBufferDisplayLayer
  InputInjector ◀──────── c / p / s messages ──────────────── touch & Pencil gestures
```

The Mac connects to the iPad, because that's the only direction usbmuxd supports. Once connected,
the existing protocol runs unchanged.

### Wire format

The messages are the ones the WebSocket carries today, framed for a plain byte stream:

```
[u32 big-endian length of the rest] [u8 kind: 0 = text, 1 = binary] [payload]
```

- Mac to iPad: the codec config (JSON text, as now), frames (binary: a 1-byte keyframe flag, then
  AVCC or HVCC) and stats (JSON text).
- iPad to Mac: `hello usb [hevc]`, `ack`, `key`, `d <ms>`, and the input messages `c`, `p` and
  `s`, unchanged (their format is in the header of `InputInjector.swift`).
- There's no token: a USB viewer already needs physical access and a trusted pairing.

### Mac side (PortraitHost)

1. `USBMux.swift` is a client for `/var/run/usbmuxd`. Each message is a 16-byte header (length,
   version 1, type 8 for plist, tag) followed by an XML plist. `Listen` delivers `Attached` and
   `Detached` events with a `DeviceID`. `Connect` (with `DeviceID` and `PortNumber`) turns the socket
   into a raw TCP tunnel to the iPad's port once the reply says `Result 0`. `PortNumber` is expected
   in network byte order inside the plist integer, as libimobiledevice sends it; the feasibility
   test confirms this.
2. An attach loop: when a device attaches with `ConnectionType` USB, it tries `Connect` to port
   20808 every second until the app answers (the app may not be open yet), and stops on `Detached`.
3. `Viewer` in `StreamServer` currently owns an `NWConnection` with WebSocket framing. A small
   `ViewerLink` interface (send text, send binary, receive a message, close) gets a WebSocket and a
   USB implementation. Flow control (4 frames in flight), keyframe handling, codec choice, stats and
   the viewer count stay shared, so the on-demand display, HEVC negotiation and the menu bar app work
   for USB viewers without changes.
4. A `--no-usb` option, and a menu line saying "iPad connected (USB)".

### iPad side (new app in an `iPad/` folder)

1. An `NWListener` on TCP port 20808, bound to loopback, which is where usbmuxd delivers the
   connection. It takes one connection at a time, and a new one replaces the old.
2. Decoding and display: the app builds a `CMVideoFormatDescription` from the avcC or hvcC in the
   codec config, wraps each frame in a `CMSampleBuffer` marked `DisplayImmediately`, and enqueues it
   on an `AVSampleBufferDisplayLayer`, which decodes in hardware. If that layer holds frames back, it
   decodes with `VTDecompressionSession` and shows the pixel buffers instead; the feasibility test
   decides which. It sends `ack` per frame and `d <ms>` for decode time, as the web page does.
3. Input follows the gesture rules in `ViewerPage.swift`. The Pencil or a mouse is the pointer, with
   pressure and tilt from `UITouch.force`, `altitudeAngle` and `azimuthAngle`. A finger tap is a
   click, a finger drag scrolls with momentum, a two-finger tap is a right-click, and a three-finger
   tap shows the overlay.
4. The app runs full screen with the status bar hidden, keeps the screen on while connected
   (`isIdleTimerDisabled`), shows the same overlay as the web page (including the size to enter in
   Settings), and says "Connect the cable and start Portrait Display on the Mac" when idle.

The USB path needs no certificate, Safari or WebCodecs, so the certificate install step goes away
for it.

## Building and signing

- It needs full Xcode. Command-line builds set `DEVELOPER_DIR` to Xcode, so the default Command
  Line Tools stay as they are for `swift build`.
- With a free Apple ID, Xcode installs the app for 7 days; after that it won't open until it's
  rebuilt and reinstalled. A paid developer account (USD 99 a year) makes an install last a year.
  Because the app is only used with the iPad plugged into the Mac, the menu bar app could reinstall
  it automatically before it expires.
- The iPad has to trust the Mac ("Trust This Computer", as for Finder sync), and Developer Mode has
  to be on (Settings → Privacy & Security) to run a self-built app.
- The cable has to carry data. A charge-only cable shows no device.

## Risks

| Risk | How we'd notice | Fallback |
|---|---|---|
| usbmuxd `Connect` to an app's port doesn't work on iPadOS 27 (the protocol is private) | The feasibility test never gets `Result 0` | Ethernet adapters |
| `AVSampleBufferDisplayLayer` adds a frame or more of delay | The test or the first build shows visible delay, or a high decode time | `VTDecompressionSession` with Metal, or a layer fed decoded pixel buffers |
| Reinstalling the free install every 7 days gets tedious | The app stops opening | Automatic reinstall, a paid account, or keeping Wi-Fi or Ethernet as the everyday path |
| The app only runs in the foreground | Switching apps on the iPad drops the stream | The same as the web page today; the on-demand display stays for the grace period |

## Plan

1. Feasibility test, about half a day: a stub iPad app that listens on 20808 and echoes bytes, and
   a Mac program that waits for the iPad, connects through usbmuxd and times 1,000 round trips. It
   passes if `Connect` succeeds, the median round trip is under 2 ms and the 99th percentile is under
   5 ms. It also sends 300 KB messages, about a keyframe's size, to check throughput. The code is in
   `Spike/usb/`.
2. The Mac transport (`USBMux.swift`, `ViewerLink` and the attach loop): about a day.
3. The iPad app (decoding, display, input and overlay): one to two days.
4. Compare the round trip and how the Pencil feels against Wi-Fi, using the stats line.

The time estimates are guesses rather than measurements. Wi-Fi keeps working throughout, alongside
USB.

## Open questions

- Does `Connect` need anything beyond the existing trust pairing on iPadOS 27? The feasibility test
  answers this.
- Should the app tell the Mac its screen size, so the virtual display can size itself instead of
  using the size in Settings?
- Free account with automatic reinstalls, or a paid account?
