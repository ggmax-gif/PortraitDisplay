# PortraitDisplay

Use an iPad as a **portrait** second screen for your Mac, through Safari over Wi-Fi.
No Sidecar, no iPad app to install.

How it works: the Mac program creates a portrait virtual monitor, captures it with
ScreenCaptureKit, and sends it as JPEG frames to a full-screen web page on the iPad.

## Run it

```bash
cd ~/workspace/PortraitDisplay
swift run -c release PortraitHost
```

The first build takes a minute. The first time it runs, macOS asks to let **Terminal** record
the screen. Allow it, then **quit Terminal completely (⌘Q)**, reopen it and run the command again.

Terminal prints an address like `http://192.168.1.23:8080/?t=…`.

## On the iPad

1. Connect the iPad to the **same Wi-Fi** as the Mac. Turn Sidecar off.
2. Open the address in Safari.
3. Tap **Share → Add to Home Screen**, then open it from the Home Screen for a full-screen view.
   The link stays the same between runs, so this only needs doing once.
4. Tap the screen to show or hide the info overlay. Double-tap for full screen in normal Safari.

## On the Mac

The new monitor is called **"Portrait iPad"**. Drag windows onto it like any other monitor.
Put it on the correct side of your MacBook in **System Settings → Displays → Arrange…**.
Press **Ctrl+C** in Terminal to stop, and the monitor disappears.

## Make it fit your iPad exactly

The overlay on the iPad shows its own size, for example `--width 820 --height 1180`.
Run with those numbers:

```bash
swift run -c release PortraitHost --width 820 --height 1180
```

Other options (`--help` lists them all):

| Option | Default | What it does |
|---|---|---|
| `--scale 1.5` | 2 | Lower = less Wi-Fi traffic, slightly softer text |
| `--quality 0.6` | 0.7 | JPEG quality: lower = smoother on slow Wi-Fi |
| `--fps 60` | 30 | Max updates per second |
| `--port 9090` | 8080 | Change if 8080/8081 are in use |
| `--no-hidpi` | off | Bigger UI, less sharp |

## Notes

* Only frames that changed are sent. A still screen uses almost no network.
* Uni Wi-Fi (eduroam) usually blocks devices from talking to each other. At uni, turn on your
  phone's hotspot and join both the Mac and the iPad to it.
* The page needs the `?t=…` key in the link, so other people on the network can't view your
  screen. The key is saved in `~/.portraitdisplay-token`. Delete that file to get a new one.
* The virtual monitor uses a private macOS API (the same one BetterDisplay uses), so this is
  for personal use, not the App Store.
