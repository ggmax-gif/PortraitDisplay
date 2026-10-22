import Foundation

/// Plain-HTTP page the printed link opens. If the iPad already trusts the certificate it forwards
/// straight to the HTTPS viewer; otherwise it walks through installing the certificate once.
enum SetupPage {
    static func html(token: String, pagePort: UInt16) -> String {
        template
            .replacingOccurrences(of: "__TOKEN__", with: token)
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
      async function check() {
        try {
          await fetch(`${target}/ping`, { mode: "no-cors", cache: "no-store" });
          location.replace(`${target}/?t=__TOKEN__`);
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
