# SemiVPN Domain Routing Chrome extension

This is a Chrome Manifest V3 unpacked extension. It installs a PAC script with
the proxy permission and sends only listed domains to
HTTP CONNECT 127.0.0.1:49280; every other host returns DIRECT.

The popup shows the active tab's hostname. An unlisted hostname gets only an
**Add to domain list** action; adding asks whether all subdomains should be
included. If not, the rule covers the exact hostname and its `www` variant.
A listed hostname shows **Active**, **Paused**, or **Passive** state, can be
paused or resumed, and can be removed from the list. The full domain list is
managed in the SemiVPN app; the extension never displays it. The popup also
shows the current VPN connection status and uses the SemiVPN application icon.

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

The popup does not duplicate SemiVPN's routing-mode selector. It shows a
danger notice only when the selected mode cannot provide browser-domain
routing. The extension only installs active domain PAC rules for Selected apps
+ browser and Browser only modes.

The extension syncs from the app once per minute and when its popup opens. The
app owns domains.json, including each domain's Active/Passive state and whether
the rule includes subdomains; Chrome storage is only a PAC cache. When the
selected mode does not include browser routing, the extension keeps the domain
list and per-domain states but routes all hosts DIRECT.
If the app API is temporarily unavailable, the extension keeps the last PAC
rather than falling back to a direct proxy. The local proxy itself also
rejects non-listed hosts and all forwarding while Browser routing or the VPN
connection is inactive.

The current implementation covers TCP HTTP and HTTPS CONNECT. QUIC/HTTP3 and
WebRTC policy controls are intentionally a follow-up: Chrome may use UDP paths
that do not go through an HTTP proxy and need separate handling.
