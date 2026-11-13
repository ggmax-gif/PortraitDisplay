import Foundation

/// Plain-HTTP page the printed link opens. If the iPad already trusts the certificate it forwards
/// straight to the HTTPS viewer; otherwise it walks through installing the certificate once.
///
/// This page is unencrypted, so it holds no secret and anyone may load it. The link carries the key
/// after "#" (`…:8080/#t=<key>`), which browsers keep to themselves; the script here hands it to the
/// HTTPS page, the first place it crosses the network.
enum SetupPage {
    static func html(pagePort: UInt16) -> String {
        template
            .replacingOccurrences(of: "__PAGE_PORT__", with: String(pagePort))
            .replacingOccurrences(of: "__CA_NAME__", with: Certificates.caName)
    }

    private static let template = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Portrait Display setup</title>
    <style>
      body { background: #000; color: #ddd; font: 17px/1.5 -apple-system, sans-serif;
             max-width: 34em; margin: 0 auto; padding: 2em 1.2em; }
      h2 { color: #fff; margin-top: 0; }
      li { margin-bottom: .8em; }
      a.button { display: inline-block; background: #0a84ff; color: #fff; text-decoration: none;
                 padding: .6em 1.1em; border-radius: 10px; font-weight: 600; }
      #checking { color: #9f9; }
      #steps { display: none; }
      .note { color: #888; font-size: 14px; }
    </style>
    </head>
    <body>
    <p id="checking">Checking the secure connection…</p>
    <p id="nokey" style="display:none">This link is incomplete. Open the full link from the Mac
    (it ends in <code>#t=…</code>): copy it from the Portrait Display menu, or scan its QR code.</p>
    <div id="steps">
      <h2>One-time setup</h2>
      <p>The video decoder in Safari only runs on secure (https) pages, so the iPad has to trust
      this Mac's certificate once.</p>
      <ol>
        <li><a class="button" href="/PortraitDisplay-CA.cer">Download certificate</a><br>
            Tap <b>Allow</b>, then <b>Close</b>.</li>
        <li>Open <b>Settings</b>. Tap <b>Profile Downloaded</b> near the top, then <b>Install</b>.</li>
        <li><b>Settings → General → About → Certificate Trust Settings</b>.
            Turn on <b>__CA_NAME__</b>.</li>
        <li>Come back here. This page moves on by itself.</li>
      </ol>
      <p class="note">The certificate can only vouch for private network addresses (like 192.168.x.x),
      not for real websites. Remove it any time in Settings → General → VPN &amp; Device Management.</p>
    </div>
    <script>
    (() => {
      const target = `https://${location.hostname}:__PAGE_PORT__`;
      // Links from older versions had the key as "?t="; they still work.
      const key = new URLSearchParams(location.hash.slice(1)).get("t")
               || new URLSearchParams(location.search).get("t") || "";
      if (!/^[A-Za-z0-9]+$/.test(key)) {
        document.getElementById("checking").style.display = "none";
        document.getElementById("nokey").style.display = "block";
        return;
      }
      async function check() {
        try {
          await fetch(`${target}/ping`, { mode: "no-cors", cache: "no-store" });
          location.replace(`${target}/?t=${key}`);
        } catch (_) {
          document.getElementById("checking").style.display = "none";
          document.getElementById("steps").style.display = "block";
        }
      }
      check();
      setInterval(check, 3000);
      document.addEventListener("visibilitychange", () => { if (!document.hidden) check(); });
    })();
    </script>
    </body>
    </html>
    """#
}
