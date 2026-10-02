# SemiVPN Domain Routing Chrome extension

This is a Chrome Manifest V3 unpacked extension. It installs a PAC script with
the proxy permission and sends only listed domains to SemiVPN's local proxy
(`[::1]:49280`, then `127.0.0.1:49280`); every other host returns DIRECT.

The popup shows the active tab's hostname. An unlisted hostname gets only an
**Add to domain list** action; adding asks whether all subdomains should be
included. If not, the rule covers the exact hostname and its `www` variant.
A listed hostname shows **Active**, **Paused**, or **Passive** state, can be
paused or resumed, and can be removed from the list. The full domain list is
managed in the SemiVPN app; the extension never displays it. The popup also
shows the current VPN connection status and uses the SemiVPN application icon.

The extension ID is pinned by the `key` in `manifest.json`
(`jaiknknmjmncnocbcbneepnefhokegma`), whatever folder it is loaded from.
SemiVPN's local control API only accepts requests from that ID. Remove the
`key` before uploading the extension to the Chrome Web Store, which assigns
its own.

## Development install

1. Build and run SemiVPN once so its localhost API is listening.
2. Open chrome://extensions, enable Developer mode, and choose Load unpacked.
3. Select this ChromeExtension directory.
4. In SemiVPN's Routing screen choose one of the four modes: All apps,
   Selected apps only, Selected apps + browser, or Browser only.
5. Connect the VPN. Browser-only mode keeps other applications direct while
   routing SemiVPN's local browser proxy through the VPN.
6. Manage the complete domain list in SemiVPN's Browser tab. In the extension,
   add the currently open website and choose its subdomain scope, or
   pause/resume/remove that current rule.

## Offline setup from the SemiVPN app

The macOS app includes a copy of this extension. Open SemiVPN's **Browser**
tab, choose **Prepare** in the Chrome extension section, then choose **Open
Chrome setup**. In Chrome, enable Developer mode and choose **Load unpacked**. Select
the folder shown in SemiVPN (normally
`~/Library/Application Support/SemiVPN/ChromeExtension`). This is a one-time
manual step per Mac; Chrome does not allow a regular macOS app to silently
install a local unpacked extension.

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

The proxy always refuses hosts that are not in the list. The extension syncs
from the app once per minute, on tab changes and when its popup opens; the
app owns `domains.json` (domains, paused state, subdomain scope and the
blocking option), and Chrome storage is only a cache. If the app API is
temporarily unavailable, the extension keeps the last PAC.

The current implementation covers TCP HTTP and HTTPS CONNECT. QUIC/HTTP3 and
WebRTC policy controls are intentionally a follow-up: Chrome may use UDP paths
that do not go through an HTTP proxy and need separate handling.
