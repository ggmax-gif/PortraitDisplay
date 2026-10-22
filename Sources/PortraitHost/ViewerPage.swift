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
      /* Keep the picture inside the safe area: in the Home Screen app the status bar and the
         home indicator are drawn over the page, and would cover the Mac's menu bar and Dock. */
      #stage { position: fixed; top: env(safe-area-inset-top); bottom: env(safe-area-inset-bottom);
               left: env(safe-area-inset-left); right: env(safe-area-inset-right); }
      canvas { width: 100%; height: 100%; display: block; }
      #hud { position: fixed; left: 10px; bottom: calc(10px + env(safe-area-inset-bottom));
             color: #9f9; background: rgba(0,0,0,.6); font: 12px ui-monospace, Menlo, monospace;
             padding: 6px 8px; border-radius: 6px; line-height: 1.5; pointer-events: none; }
      #hud.hidden { display: none; }
    </style>
    </head>
    <body>
    <div id="stage"><canvas id="c"></canvas></div>
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
      let pipeline = "", received = new Map(), decodeSum = 0, decodeCount = 0;
      let wakeLock = null, hudTimer = null;

      function resize() {
        const dpr = window.devicePixelRatio || 1;
        const box = canvas.getBoundingClientRect();
        canvas.width = Math.round(box.width * dpr);
        canvas.height = Math.round(box.height * dpr);
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
        const box = canvas.getBoundingClientRect();
        const area = { w: Math.round(box.width), h: Math.round(box.height) };
        const size = codec ? `${codec.width}×${codec.height}` : "–";
        hud.innerHTML =
          `${status}<br>` +
          (pipeline ? `${pipeline}<br>` : "") +
          `${rate} updates/s · ${kbps >= 1000 ? (kbps / 1000).toFixed(1) + " Mbit/s" : kbps + " kbit/s"}` +
          ` · H.264 ${size}<br>` +
          `usable area: ${area.w}×${area.h} pt ` +
          `→ <b>--width ${Math.min(area.w, area.h)} --height ${Math.max(area.w, area.h)}</b><br>` +
          `Pencil: point &amp; drag · finger: tap = click, drag = scroll<br>` +
          `2-finger tap = right-click · 3-finger tap = hide/show this`;
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
        received.clear();
        if (!codec) return;
        decoder = new VideoDecoder({
          output: (frame) => {
            const t0 = received.get(frame.timestamp);
            if (t0 !== undefined) {
              received.delete(frame.timestamp);
              decodeSum += performance.now() - t0; decodeCount++;
            }
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
        received.set(timestamp, performance.now());
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
            const message = JSON.parse(event.data);
            if (message.stats) { pipeline = message.stats; updateHud(); return; }
            codec = message;
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

      // ---- Input. Pencil (or a mouse) is the pointer: tap clicks, drag drags.
      // Fingers: tap = click, drag = scroll (with momentum), two-finger tap = right-click,
      // three-finger tap = show/hide the overlay. Positions are sent as 0–1 across the stream.
      const touches = new Map();   // pointerId -> {x, y}
      let gesture = null, momentum = null;
      const f = (v) => Number.isFinite(v) ? v.toFixed(5) : "0";   // a zero-size layout would give NaN

      function streamRect() {
        const box = canvas.getBoundingClientRect();
        const s = Math.min(box.width / codec.width, box.height / codec.height);
        const w = codec.width * s, h = codec.height * s;
        return { x: box.left + (box.width - w) / 2, y: box.top + (box.height - h) / 2, w, h };
      }
      function at(x, y) { const r = streamRect(); return `${f((x - r.x) / r.w)} ${f((y - r.y) / r.h)}`; }
      function delta(dx, dy) { const r = streamRect(); return `${f(dx / r.w)} ${f(dy / r.h)}`; }
      function centroid() {
        let x = 0, y = 0;
        for (const t of touches.values()) { x += t.x; y += t.y; }
        return { x: x / touches.size, y: y / touches.size };
      }
      function pen(e) {
        return `${f(e.pressure || 0.5)} ${f((e.tiltX || 0) / 90)} ${f((e.tiltY || 0) / 90)}`;
      }

      function stopMomentum() {
        if (momentum) { send("s me"); momentum = null; }
      }
      function runMomentum(now) {
        if (!momentum) return;
        const dt = Math.min(now - momentum.last, 50);
        momentum.last = now;
        const dx = momentum.vx * dt, dy = momentum.vy * dt;
        send(`s ${momentum.started ? "mc" : "mb"} ${delta(dx, dy)}`);
        momentum.started = true;
        const decay = Math.pow(0.95, dt / 16.7);
        momentum.vx *= decay; momentum.vy *= decay;
        if (Math.hypot(momentum.vx, momentum.vy) < 0.02) { stopMomentum(); return; }
        requestAnimationFrame(runMomentum);
      }

      canvas.addEventListener("pointerdown", (e) => {
        e.preventDefault();
        if (!codec) return;
        if (e.pointerType !== "touch") {
          canvas.setPointerCapture(e.pointerId);
          send(`p d ${at(e.clientX, e.clientY)} ${pen(e)} ${e.button === 2 ? 1 : 0}`);
          return;
        }
        stopMomentum();
        touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
        const c = centroid();
        if (!gesture) {
          gesture = { kind: "pending", start: c, startTime: performance.now(), fingers: 1, last: c, samples: [] };
        } else {
          gesture.fingers = Math.max(gesture.fingers, touches.size);
          gesture.last = c;   // re-anchor so adding a finger doesn't jump the scroll
        }
      });

      canvas.addEventListener("pointermove", (e) => {
        if (!codec) return;
        if (e.pointerType !== "touch") {
          send(e.buttons ? `p m ${at(e.clientX, e.clientY)} ${pen(e)}` : `p h ${at(e.clientX, e.clientY)}`);
          return;
        }
        if (!touches.has(e.pointerId) || !gesture) return;
        touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
        const c = centroid();
        if (gesture.kind === "pending" && gesture.fingers <= 2 &&
            Math.hypot(c.x - gesture.start.x, c.y - gesture.start.y) > 10) {
          gesture.kind = "scroll";
          send(`s b ${at(gesture.start.x, gesture.start.y)} ${delta(c.x - gesture.last.x, c.y - gesture.last.y)}`);
          gesture.last = c;
          return;
        }
        if (gesture.kind !== "scroll") return;
        const dx = c.x - gesture.last.x, dy = c.y - gesture.last.y;
        gesture.last = c;
        const now = performance.now();
        gesture.samples.push({ t: now, dx, dy });
        while (gesture.samples.length && now - gesture.samples[0].t > 100) gesture.samples.shift();
        send(`s c ${delta(dx, dy)}`);
      });

      function pointerEnd(e) {
        if (e.pointerType !== "touch") {
          if (codec) send(`p u ${at(e.clientX, e.clientY)}`);
          return;
        }
        if (!touches.delete(e.pointerId) || !gesture) return;
        if (touches.size > 0) { gesture.last = centroid(); return; }   // wait for the last finger
        const g = gesture;
        gesture = null;
        if (g.kind === "scroll") {
          send("s e");
          const now = performance.now();
          const recent = g.samples.filter((s) => now - s.t < 100);
          const span = recent.length ? now - recent[0].t + 8 : 0;
          if (span > 0 && e.type === "pointerup") {
            const vx = recent.reduce((a, s) => a + s.dx, 0) / span;
            const vy = recent.reduce((a, s) => a + s.dy, 0) / span;
            if (Math.hypot(vx, vy) > 0.3) {
              momentum = { vx, vy, last: now, started: false };
              requestAnimationFrame(runMomentum);
            }
          }
        } else if (e.type === "pointerup" && performance.now() - g.startTime < 400) {
          if (g.fingers === 1) send(`c ${at(g.start.x, g.start.y)} 0`);
          else if (g.fingers === 2) send(`c ${at(g.start.x, g.start.y)} 1`);
          else hud.classList.toggle("hidden");
        }
      }
      canvas.addEventListener("pointerup", pointerEnd);
      canvas.addEventListener("pointercancel", pointerEnd);
      canvas.addEventListener("contextmenu", (e) => e.preventDefault());

      // Stop Safari's own double-tap zoom and callouts; touchend also counts as a user gesture for the wake lock.
      document.addEventListener("touchend", (e) => { e.preventDefault(); keepAwake(); }, { passive: false });
      document.addEventListener("click", keepAwake);
      document.addEventListener("visibilitychange", () => { if (!document.hidden) keepAwake(); });
      window.addEventListener("resize", () => { resize(); updateHud(); });

      setInterval(() => {
        rate = frames; frames = 0;
        kbps = Math.round(bytes * 8 / 1000); bytes = 0;
        if (decodeCount) { send(`d ${(decodeSum / decodeCount).toFixed(1)}`); decodeSum = 0; decodeCount = 0; }
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
