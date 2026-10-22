# PortraitDisplay

Use an iPad as a **portrait** second screen for your Mac, through Safari over Wi-Fi.
No Sidecar, no iPad app to install.

How it works: the Mac program creates a portrait virtual monitor, captures it with
ScreenCaptureKit, encodes it as H.264 video in hardware, and streams it to a full-screen web page
on the iPad, which decodes it in hardware with WebCodecs.

## Run it

```bash
cd ~/workspace/PortraitDisplay
swift run -c release PortraitHost
```

The first build takes a minute. The first time it runs, macOS asks to let **Terminal** record
the screen. Allow it, then **quit Terminal completely (⌘Q)**, reopen it and run the command again.

Terminal prints an address like `http://192.168.1.23:8080/?t=…`.

## Or: menu bar app

```bash
scripts/make-app.sh
open ~/Applications/"Portrait Display.app"
```

This builds **Portrait Display.app** into `~/Applications` and puts an iPad icon in the menu bar,
with Start / Stop, the iPad link (copy it or show it as a QR code to scan), whether the iPad is
connected, the latest stats, and Launch at Login. The icon is dimmed while it's off.

The app needs its own permissions (not Terminal's): Screen & System Audio Recording, and
Accessibility for touch input. If Start fails, the alert has a button to the right settings page.
The script signs the app with a local certificate kept in `~/.portraitdisplay/signing`, so
those permissions survive rebuilds. Don't delete that folder, or macOS asks again.

Options go in the app's settings instead of on the command line, for example:

```bash
defaults write com.danielfung.PortraitDisplay hostArguments -array --width 820 --height 1180
defaults write com.danielfung.PortraitDisplay startOnLaunch -bool YES   # start right away (e.g. at login)
```

Output from each run is in `~/Library/Logs/PortraitDisplay.log` (Show Log in the menu).

## On the iPad

1. Connect the iPad to the **same Wi-Fi** as the Mac. Turn Sidecar off. iPadOS 16.4 or later.
2. Open the address in Safari.
3. **First time only:** the page asks you to install the Mac's certificate. Safari only runs the
   video decoder on secure (https) pages, and this certificate makes the iPad trust the Mac.
   Download it, install it in **Settings → Profile Downloaded**, then turn it on in
   **Settings → General → About → Certificate Trust Settings**. The page then opens the display
   by itself, at an `https://…:8081` address.
4. On that page tap **Share → Add to Home Screen**, then open it from the Home Screen for a
   full-screen view. The link stays the same between runs, so this only needs doing once.
   (A Home Screen icon from the old JPEG version points at the http page; delete it and re-add.)
5. Tap with three fingers to show or hide the info overlay.

## Touch and Apple Pencil

| On the iPad | On the Mac |
|---|---|
| Pencil tap / drag | Click / drag (with pressure and tilt) |
| Finger tap | Click (tap twice for a double-click) |
| Finger drag, one or two fingers | Scroll, with momentum |
| Two-finger tap | Right-click |
| Three-finger tap | Show or hide the overlay |

A mouse or trackpad connected to the iPad works like the Pencil.
This needs **Accessibility** permission for Terminal on the Mac: System Settings → Privacy & Security
→ Accessibility. Run with `--no-input` to keep the iPad view-only.

## On the Mac

The new monitor is called **"Portrait iPad"**. Drag windows onto it like any other monitor.
Put it on the correct side of your MacBook in **System Settings → Displays → Arrange…**.
Press **Ctrl+C** in Terminal to stop, and the monitor disappears.

## Make it fit your iPad exactly

The default, 1024×1334, fits an iPad Pro 12.9" running the Home Screen app (its status bar
takes 32 of the 1366 points). For any other iPad, or in a Safari tab, the overlay shows the size
to use, for example `--width 820 --height 1180`. Run with those numbers:

```bash
swift run -c release PortraitHost --width 820 --height 1180
```

Other options (`--help` lists them all):

| Option | Default | What it does |
|---|---|---|
| `--scale 1.5` | 2 | Lower = less Wi-Fi traffic, slightly softer text |
| `--bitrate 10` | 20 | Video cap in Mbit/s while things move. Lower for slow Wi-Fi |
| `--codec hevc` | h264 | About 40% less data while scrolling, half when the whole screen changes; text a little softer once the screen is still. Falls back to H.264 for an iPad that can't decode HEVC |
| `--fps 30` | 60 | Max updates per second. Lower it if the iPad can't keep up |
| `--port 9090` | 8080 | Uses this port and the next two (8080–8082). Change if they're taken |
| `--no-hidpi` | off | Bigger UI, less sharp |
| `--no-input` | off | Ignore touch and Pencil (view only) |

## Notes

* Only frames that changed are sent. A still screen uses almost no network. If the Wi-Fi can't
  keep up, frames are skipped and the stream restarts from a fresh keyframe, so it never lags behind.
* The certificate authority lives in `~/.portraitdisplay/`. It can only vouch for private network
  addresses (10.x, 172.16–31.x, 192.168.x, 100.64–127.x), not for real websites, and a new server
  certificate is issued for the Mac's current addresses every run. Delete the folder (and the
  profile on the iPad) to start over.
* Uni Wi-Fi (eduroam) usually blocks devices from talking to each other. At uni, turn on your
  phone's hotspot and join both the Mac and the iPad to it.
* The page needs the `?t=…` key in the link, so other people on the network can't view your
  screen. The key is saved in `~/.portraitdisplay-token`. Delete that file to get a new one.
* The virtual monitor uses a private macOS API (the same one BetterDisplay uses), so this is
  for personal use, not the App Store.
