import Foundation

/// The page the iPad opens in Safari. Draws each JPEG frame full screen and asks for the next one.
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
      let ws = null, current = null, frames = 0, rate = 0, status = "connecting…";
      let wakeLock = null, hudTimer = null;

      function resize() {
        const dpr = window.devicePixelRatio || 1;
        canvas.width = Math.round(window.innerWidth * dpr);
        canvas.height = Math.round(window.innerHeight * dpr);
        draw();
      }

      function draw() {
        ctx.fillStyle = "#000";
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        if (!current) return;
        const s = Math.min(canvas.width / current.width, canvas.height / current.height);
        const w = current.width * s, h = current.height * s;
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = "high";
        ctx.drawImage(current, (canvas.width - w) / 2, (canvas.height - h) / 2, w, h);
      }

      function updateHud() {
        const img = current ? `${current.width}×${current.height}` : "–";
        hud.innerHTML =
          `${status}<br>` +
          `${rate} updates/s · stream ${img}<br>` +
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

      function connect() {
        status = "connecting…"; updateHud();
        ws = new WebSocket(`ws://${location.hostname}:${WS_PORT}/`);
        ws.binaryType = "arraybuffer";
        ws.onopen = () => {
          status = "connected";
          ws.send("hello " + TOKEN);
          ws.send("next");
          updateHud(); showHudBriefly();
        };
        ws.onmessage = async (event) => {
          if (typeof event.data === "string") return;
          try {
            const bitmap = await createImageBitmap(new Blob([event.data], { type: "image/jpeg" }));
            const old = current;
            current = bitmap;
            draw();
            if (old && old.close) old.close();
            frames++;
          } catch (e) {
            console.error(e);
          }
          if (ws && ws.readyState === WebSocket.OPEN) ws.send("next");
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

      setInterval(() => { rate = frames; frames = 0; updateHud(); }, 1000);
      resize();
      connect();
    })();
    </script>
    </body>
    </html>
    """#
}
