import Foundation

/// The page the iPad opens in Safari (over HTTPS). Decodes the H.264 stream with WebCodecs,
/// draws the newest frame full screen and acknowledges every frame it receives.
enum ViewerPage {
    static func html(token: String, wsPort: UInt16, name: String) -> String {
        template
            .replacingOccurrences(of: "__TOKEN__", with: token)
            .replacingOccurrences(of: "__WS_PORT__", with: String(wsPort))
            .replacingOccurrences(of: "__NAME__", with: name)
    }

    static func manifest(token: String, name: String) -> String {
        """
        {
          "name": "\(name)",
          "short_name": "Portrait",
          "start_url": "/?t=\(token)",
          "display": "fullscreen",
          "orientation": "any",
          "background_color": "#000000",
          "theme_color": "#000000"
        }
        """
    }

    static let wrongLink = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <body style="background:#000;color:#ccc;font:17px -apple-system,sans-serif;padding:2em">
    <h2>Link missing its key</h2>
    <p>Open the full address printed in the Mac's Terminal window (it ends in <code>?t=…</code>).</p>
    </body>
    """

    private static let template = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Portrait">
    <link rel="manifest" href="/manifest.webmanifest?t=__TOKEN__">
    <title>__NAME__</title>
    <style>
      html, body { margin: 0; height: 100%; background: #000; overflow: hidden;
                   touch-action: none; -webkit-user-select: none; user-select: none;
                   -webkit-touch-callout: none; }
      canvas { position: fixed; inset: 0; width: 100vw; height: 100vh; display: block; }
      #hud { position: fixed; left: 10px; bottom: calc(10px + env(safe-area-inset-bottom));
             color: #9f9; background: rgba(0,0,0,.6); font: 12px ui-monospace, Menlo, monospace;
             padding: 6px 8px; border-radius: 6px; line-height: 1.5; pointer-events: none; }
      #hud.hidden { display: none; }
    </style>
    </head>
    <body>
    <canvas id="c"></canvas>
    <div id="hud">connecting…</div>
    <script>
    (() => {
      const TOKEN = "__TOKEN__";
      const WS_PORT = __WS_PORT__;
      const canvas = document.getElementById("c");
      const ctx = canvas.getContext("2d", { alpha: false });
      const hud = document.getElementById("hud");
      let ws = null, decoder = null, codec = null, needKey = true, timestamp = 0;
      let current = null, drawPending = false;
      let frames = 0, bytes = 0, rate = 0, kbps = 0, status = "connecting…";
      let wakeLock = null, hudTimer = null;

      function resize() {
        const dpr = window.devicePixelRatio || 1;
        canvas.width = Math.round(window.innerWidth * dpr);
        canvas.height = Math.round(window.innerHeight * dpr);
        draw();
      }

      function draw() {
        drawPending = false;
        ctx.fillStyle = "#000";
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        if (!current) return;
        const fw = current.displayWidth, fh = current.displayHeight;
        const s = Math.min(canvas.width / fw, canvas.height / fh);
        const w = fw * s, h = fh * s;
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = "high";
        ctx.drawImage(current, (canvas.width - w) / 2, (canvas.height - h) / 2, w, h);
      }

      function updateHud() {
        const size = codec ? `${codec.width}×${codec.height}` : "–";
        hud.innerHTML =
          `${status}<br>` +
          `${rate} updates/s · ${kbps >= 1000 ? (kbps / 1000).toFixed(1) + " Mbit/s" : kbps + " kbit/s"}` +
          ` · H.264 ${size}<br>` +
          `this iPad: ${window.innerWidth}×${window.innerHeight} pt ` +
          `→ <b>--width ${Math.min(window.innerWidth, window.innerHeight)} ` +
          `--height ${Math.max(window.innerWidth, window.innerHeight)}</b><br>` +
          `tap to hide/show · double-tap for full screen`;
      }

      function showHudBriefly() {
        hud.classList.remove("hidden");
        clearTimeout(hudTimer);
        hudTimer = setTimeout(() => hud.classList.add("hidden"), 8000);
      }

      function send(text) {
        if (ws && ws.readyState === WebSocket.OPEN) ws.send(text);
      }

      // (Re)creates the decoder from the last codec config; the next frame it accepts must be a keyframe.
      function resetDecoder() {
        if (decoder && decoder.state !== "closed") { try { decoder.close(); } catch (_) {} }
        decoder = null;
        needKey = true;
        if (!codec) return;
        decoder = new VideoDecoder({
          output: (frame) => {
            // Keep only the newest frame; draw it on the next screen refresh.
            if (current) current.close();
            current = frame;
            frames++;
            if (!drawPending) { drawPending = true; requestAnimationFrame(draw); }
          },
          error: (e) => {
            console.error(e);
            status = "decoder error – resyncing";
            updateHud();
            resetDecoder();
            send("key");
          },
        });
        const description = Uint8Array.from(atob(codec.description), (c) => c.charCodeAt(0));
        decoder.configure({
          codec: codec.codec, description, codedWidth: codec.width, codedHeight: codec.height,
          hardwareAcceleration: "prefer-hardware", optimizeForLatency: true,
        });
      }

      function onFrame(buffer) {
        bytes += buffer.byteLength;
        send("ack");
        const isKey = new Uint8Array(buffer, 0, 1)[0] === 1;
        if (!decoder || decoder.state !== "configured") return;
        if (needKey && !isKey) return;
        needKey = false;
        timestamp += 16667;   // the decoder needs increasing timestamps; frames are drawn on arrival
        try {
          decoder.decode(new EncodedVideoChunk({
            type: isKey ? "key" : "delta", timestamp, data: new Uint8Array(buffer, 1),
          }));
        } catch (e) {
          console.error(e);
          resetDecoder();
          send("key");
        }
      }

      function connect() {
        status = "connecting…"; updateHud();
        ws = new WebSocket(`wss://${location.hostname}:${WS_PORT}/`);
        ws.binaryType = "arraybuffer";
        ws.onopen = () => {
          status = "connected";
          ws.send("hello " + TOKEN);
          updateHud(); showHudBriefly();
        };
        ws.onmessage = (event) => {
          if (typeof event.data === "string") {
            codec = JSON.parse(event.data);
            resetDecoder();
            updateHud();
          } else {
            onFrame(event.data);
          }
        };
        ws.onclose = () => {
          status = "disconnected – is PortraitHost running on the Mac? retrying…";
          hud.classList.remove("hidden");
          updateHud();
          setTimeout(connect, 1500);
        };
        ws.onerror = () => { try { ws.close(); } catch (_) {} };
      }

      async function keepAwake() {
        try {
          if ("wakeLock" in navigator && (!wakeLock || wakeLock.released)) {
            wakeLock = await navigator.wakeLock.request("screen");
          }
        } catch (_) {}
      }

      let lastTap = 0;
      document.addEventListener("touchend", (e) => {
        e.preventDefault();
        keepAwake();
        const now = Date.now();
        if (now - lastTap < 300) {
          const el = document.documentElement;
          const fs = el.requestFullscreen || el.webkitRequestFullscreen;
          if (fs) { try { fs.call(el); } catch (_) {} }
        } else {
          hud.classList.toggle("hidden");
        }
        lastTap = now;
      }, { passive: false });
      document.addEventListener("click", keepAwake);
      document.addEventListener("visibilitychange", () => { if (!document.hidden) keepAwake(); });
      window.addEventListener("resize", () => { resize(); updateHud(); });

      setInterval(() => {
        rate = frames; frames = 0;
        kbps = Math.round(bytes * 8 / 1000); bytes = 0;
        updateHud();
      }, 1000);
      resize();
      if (!("VideoDecoder" in window)) {
        status = "This Safari has no WebCodecs video decoder. Update iPadOS to 16.4 or later.";
        updateHud();
        return;
      }
      connect();
    })();
    </script>
    </body>
    </html>
    """#
}
