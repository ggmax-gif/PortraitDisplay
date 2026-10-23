# USB connection: design

Status: proposal, not started. Written 2026-10-23.

## Goal

Stream to the iPad over one USB-C cable instead of Wi-Fi: no dependence on the network (the
Ask4 802.1X network may not let devices reach each other at all), and lower, steadier latency.
No internet connection is involved; the cable is only a data link.

What Wi-Fi costs today, from the stats line on this Mac: 0.0–1.4 Mbit/s used, round trip
12–160 ms, spikes to 440 ms when a stream starts. Bandwidth is not the problem; latency and the
network are. Target over USB: round trip under 5 ms (a target, not yet measured).

## Why a native iPad app

Safari can only reach the Mac over IP. Over a plain USB cable, IP needs Personal Hotspot over
USB, which needs a carrier plan; this iPad has none. The only other data channel over the cable
is usbmuxd, which Xcode and Finder use. It lets a **Mac** process open a TCP connection to a
port an **iPad app** is listening on (the PeerTalk library is built on this). Safari can't listen,
so the iPad side has to be an app.

Checked on this Mac: `/var/run/usbmuxd` exists, is `srw-rw-rw-` (no root needed), and answered
a `ListDevices` request (protocol version 1).

Alternatives considered:

| Option | Why not (for now) |
|---|---|
| USB Personal Hotspot | Needs a carrier plan. |
| USB-C Ethernet adapters + cable | Works with today's code (manual IPs, or a small change to allow 169.254.x link-local addresses), but it's two adapters, not one cable. Still the fallback if the spike below fails. |
| Phone hotspot (both devices join it) | Works now with no code, but it's still Wi-Fi latency. |

## Architecture

```
Mac                                                    iPad
PortraitHost                                           PortraitViewer (new app)
  Capturer → VideoEncoder → StreamServer                 NWListener on port 20808
                              ├─ Wi-Fi viewers (WebSocket, unchanged)
                              └─ USB viewers ── usbmuxd ── cable ──▶ decode → AVSampleBufferDisplayLayer
  InputInjector ◀──────── c / p / s messages ──────────────── touch & Pencil gestures
```

The Mac connects to the iPad, not the other way round, because that's the direction usbmuxd
supports. Everything after the connection is the existing protocol.

### Wire format

Same messages as the WebSocket today, framed for a plain stream:

```
[u32 big-endian length of the rest] [u8 kind: 0 = text, 1 = binary] [payload]
```

- Mac → iPad: codec config (JSON text, as now), frames (binary: 1-byte keyframe flag + AVCC/HVCC),
  stats (JSON text).
- iPad → Mac: `hello usb [hevc]`, `ack`, `key`, `d <ms>`, input `c`/`p`/`s …` (unchanged; format
  in the header of `InputInjector.swift`).
- No token: a USB viewer needs physical access and a trusted pairing already.

### Mac side (PortraitHost)

1. **`USBMux.swift`**: a client for `/var/run/usbmuxd`. Each message is a 16-byte header (length,
   version 1, type 8 = plist, tag) plus an XML plist. `Listen` gives `Attached` / `Detached` events
   with a `DeviceID`. `Connect` (`DeviceID`, `PortNumber`) turns the socket into a raw TCP tunnel
   to the iPad's port once it answers `Result 0`. `PortNumber` is expected in network byte order
   inside the plist integer (as libimobiledevice does); the spike confirms it.
2. **Attach loop**: on `Attached` with `ConnectionType` USB, try `Connect` to port 20808 every
   second until the app answers (it may not be open yet); stop on `Detached`.
3. **Connection abstraction in `StreamServer`**: `Viewer` currently owns an `NWConnection` with
   WebSocket framing. Split out a small `ViewerLink` (send text, send binary, receive message, close)
   with a WebSocket and a USB implementation. Flow control (4 frames in flight), keyframe logic,
   codec choice, stats and the viewer count stay shared, so on-demand display, HEVC negotiation
   and the menu bar app work for USB viewers unchanged.
4. A `--no-usb` option, and a menu line showing "iPad connected (USB)".

### iPad side (new app, `iPad/` folder, Xcode project)

1. **Listener**: `NWListener` on TCP 20808 (loopback is enough; usbmuxd delivers it locally).
   One connection at a time; a new one replaces the old.
2. **Decode and show**: build a `CMVideoFormatDescription` from the avcC / hvcC in the codec
   config, wrap each frame in a `CMSampleBuffer` marked `DisplayImmediately`, and enqueue it on an
   `AVSampleBufferDisplayLayer`, which decodes in hardware. If that layer holds frames back, decode
   with `VTDecompressionSession` and show the pixel buffers instead (the spike decides).
   Send `ack` per frame and `d <ms>` for decode time, as the web page does.
3. **Input**: port the gesture rules from `ViewerPage.swift`: Pencil or mouse = pointer with
   pressure and tilt (`UITouch.force`, `altitudeAngle`, `azimuthAngle`); finger tap = click; finger
   drag = scroll with momentum; two-finger tap = right-click; three-finger tap = overlay.
4. **Rest**: full screen, status bar hidden, `isIdleTimerDisabled` while connected, an overlay with
   the same info as the web page's (including the size to put in Settings), and "Connect the cable
   and start Portrait Display on the Mac" when idle.

No certificate, no Safari and no WebCodecs: the CA install step disappears for USB.

## Building and signing

- Needs full Xcode (installed). Build from the command line with `DEVELOPER_DIR` pointing at
  Xcode, so the default Command Line Tools stay as they are for `swift build`.
- **Free Apple ID**: Xcode installs the app for 7 days, then it stops opening until rebuilt and
  reinstalled. A **paid developer account** (USD 99/year) makes an install last a year.
- The iPad must trust the Mac ("Trust This Computer"), as for Finder sync, and Developer Mode must
  be on (Settings → Privacy & Security) to run a self-built app.
- The cable must carry data; a charge-only cable shows no device.

## Risks

| Risk | How we'd notice | Fallback |
|---|---|---|
| usbmuxd `Connect` to an app port doesn't work on iPadOS 27 (private protocol) | The spike gets no `Result 0` | Ethernet adapters |
| `AVSampleBufferDisplayLayer` adds a frame or more of delay | Spike or first build: delay visible, or decode time high | `VTDecompressionSession` + Metal / layer of pixel buffers |
| The 7-day free install expiring is a chore | It stops opening | Paid account, or keep Wi-Fi/Ethernet as the everyday path |
| The app only runs in the foreground | Switching apps on the iPad drops the stream | Same as the web page today; on-demand removes the display after 15 s |

## Plan

1. **Spike (about half a day).** A stub iPad app that listens on 20808 and echoes bytes, and a Mac
   script that waits for the iPad, connects through usbmuxd and times 1,000 round trips.
   Pass: `Connect` succeeds, and the round-trip median is under 2 ms and the 99th percentile under 5 ms.
   Also send a 300 KB message (a keyframe's size) to check throughput.
2. **Mac transport** (`USBMux.swift`, `ViewerLink`, attach loop): about a day.
3. **iPad app** (decode, display, input, overlay): about one to two days.
4. Compare round trip and Pencil feel against Wi-Fi with the stats line.

The time estimates are guesses, not measurements. Wi-Fi keeps working throughout; USB is an
extra path, not a replacement.

## Open questions

- Does `Connect` need anything beyond the existing trust pairing on iPadOS 27? (Spike.)
- Should the app tell the Mac its screen size, so the virtual display can size itself instead of
  using the size in Settings?
- Free account (weekly reinstall) or paid account?
