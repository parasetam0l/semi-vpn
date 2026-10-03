# SemiVPN Domain Routing extension

This is a Manifest V3 extension for Google Chrome and other Chromium browsers
(Edge, Brave, Vivaldi, Opera, Arc). It installs a PAC script with the proxy
permission and sends only listed domains to SemiVPN's local proxy
(`[::1]:49280`, then `127.0.0.1:49280`); every other host returns DIRECT.

The popup shows the active tab's hostname. An unlisted hostname gets only an
**Add to domain list** action; adding asks whether all subdomains should be
included. If not, the rule covers the exact hostname and its `www` variant.
A listed hostname shows **Active**, **Paused**, or **Passive** state, can be
paused or resumed, and can be removed from the list. The full domain list is
managed in the SemiVPN app; the extension never displays it. The popup also
shows the current VPN connection status and the extension's version.

The extension ID is pinned by the `key` in `manifest.json`
(`jaiknknmjmncnocbcbneepnefhokegma`), whatever folder or browser it is loaded
in. SemiVPN's local control API only accepts requests from that ID. Remove
the `key` before uploading the extension to the Chrome Web Store, which
assigns its own.

## Setup

Chrome on macOS installs extensions only from the Chrome Web Store, or by
policy on Macs managed through MDM, so the extension is loaded unpacked once
per browser profile:

1. In SemiVPN's **Browser** tab, choose **Set up in Google Chrome…** (or
   another installed browser). SemiVPN copies the extension to
   `~/Library/Application Support/SemiVPN/ChromeExtension`.
2. Open the browser's Extensions page from the setup sheet and turn on
   **Developer mode**.
3. Drag the folder from the sheet onto the Extensions page, or choose **Load
   unpacked**, press ⌘⇧G and paste the copied path.

The sheet completes when the extension first checks in. The Browser tab then
lists every browser profile running the extension, with its version and
state.

## Updates

Each SemiVPN build stamps the bundled extension with a fingerprint of its
files (`version_name`, e.g. `0.4.0 (1a2b3c4)`), and the app copies a new
build into the extension folder when it starts. The extension reports the
build it runs with each status request (about once a minute).

A browser loads the new files only when the user clicks the extension's
Reload button on its Extensions page: `chrome.runtime.reload()` does not
re-read an unpacked extension's files (tested in Chrome and Chrome for
Testing; it can even leave the extension unloaded, which would drop its
PAC), so the extension never reloads itself. Until the user reloads it, the
popup shows an "Extension update ready" card that opens the Extensions page,
tabs without a routing badge show `UPD`, and the app's Browser tab shows the
steps and notifies once per build. If the old version stays after a reload,
the browser loads the extension from another folder; the card shows the
folder to load instead.

## Development

Loading this `ChromeExtension/` directory directly works for development.
Such a copy is never updated by the app, so after an app update the popup
and the app report it as outdated; reload it after editing.
`node Scripts/extension-tests.mjs` tests the update logic.

## Routing behavior

The popup does not duplicate SemiVPN's routing-mode selector. It shows a
danger notice only when the selected mode cannot provide browser-domain
routing. The extension only installs domain PAC rules for Selected apps +
browser and Browser only modes; otherwise every host is DIRECT.

In those modes, active (not paused) listed domains always go to the local
proxy, and the proxy follows the VPN state:

- **VPN connected:** the proxy forwards through the VPN.
- **VPN disconnected, default:** the proxy connects directly, so listed sites
  keep working without the VPN (the badge shows `DISC`). If the SemiVPN app is
  not running at all, Chrome falls back to DIRECT as well.
- **VPN disconnected, "Block listed domains while the VPN is disconnected"
  enabled in the app:** the proxy refuses the connection and the PAC has no
  DIRECT fallback, so listed sites never use the regular connection (the
  badge shows `BLK`).
- **VPN connected, but macOS routes SemiProxy outside it** (a per-app rule
  that macOS did not refresh after an update): the popup says "Not going
  through the VPN", the badge shows `!` (`BLK` when listed domains are
  blocked, which the proxy then does), and the SemiVPN app offers **Repair
  VPN Routing…**.

The proxy always refuses hosts that are not in the list. The extension syncs
from the app once per minute, on tab changes and when its popup opens; the
app owns `domains.json` (domains, paused state, subdomain scope and the
blocking option), and Chrome storage is only a cache. If the app API is
temporarily unavailable, the extension keeps the last PAC.

The current implementation covers TCP HTTP and HTTPS CONNECT. QUIC/HTTP3 and
WebRTC policy controls are intentionally a follow-up: Chrome may use UDP paths
that do not go through an HTTP proxy and need separate handling.
