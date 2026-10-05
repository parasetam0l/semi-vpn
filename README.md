# SemiVPN

[![macOS](https://img.shields.io/badge/macOS-14.0%2B%20%28Sonoma%29-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%20%2F%206.0-orange?logo=swift)](https://swift.org)
[![NetworkExtension](https://img.shields.io/badge/Framework-NetworkExtension-blue)](https://developer.apple.com/documentation/networkextension)
[![OpenVPN](https://img.shields.io/badge/Protocol-OpenVPN%202.6%20%2F%202.7-brightgreen)](https://openvpn.net/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/Tests-71%20unit%20%2B%2059%20end--to--end-success)](Tests/)

**SemiVPN** is a native macOS VPN client built completely from scratch in Swift. It implements the OpenVPN 2.6/2.7 wire protocols directly in userland—requiring **no official OpenVPN daemon**, **no legacy TUN/TAP kernel extensions**, and no external command-line utilities.

SemiVPN delivers unprecedented routing flexibility on macOS: connect system-wide in **full-tunnel mode**, route specific apps using **native macOS per-app VPN routing (`NEAppRule`)**, or isolate web traffic on a per-domain basis via an **integrated Chrome Manifest V3 companion extension**.

---

## Table of Contents

- [Features](#features)
- [Routing Modes](#routing-modes)
- [Architecture](#architecture)
- [Chrome Companion Extension](#chrome-companion-extension)
- [CLI Tool (`ovpn-cli`)](#cli-tool-ovpn-cli)
- [Building and Installation](#building-and-installation)
  - [Prerequisites](#prerequisites)
  - [One-Step Build & Install](#one-step-build--install)
  - [Manual Xcode Build](#manual-xcode-build)
  - [Running Unit Tests](#running-unit-tests)
- [Repository Layout](#repository-layout)
- [Verified Compatibility](#verified-compatibility)
- [Known Limitations](#known-limitations)
- [Distribution & Signing](#distribution--signing)
- [License](#license)

---

## Features

- **Pure Swift Protocol Engine**: Full userland implementation of the OpenVPN wire protocol, built against OpenVPN 2.6 and 2.7 specifications with zero dependency on the upstream OpenVPN C codebase.
- **Native macOS Per-App VPN**: Uses Apple's modern Network Extension APIs (`NETunnelProviderManager.forPerAppVPN` and `NEAppRule`) so selected applications route all their TCP, UDP, and QUIC traffic through the tunnel at the OS kernel level.
- **Granular Domain Split-Tunneling**: Route specific web domains (and optional subdomains) through the tunnel while keeping the rest of your browsing direct.
- **SemiProxy Auxiliary Agent**: Lightweight background proxy helper (`com.semivpn.proxy`) registered with LaunchServices (`LSUIElement: true`) for seamless OS-level routing without Dock clutter.
- **Compact Native Interface**: One window: the top shows the connection on a color that follows its state (the brand gradient while connected, gray when not) with a power button, the time connected, and the profile and route as menus; below it, a sheet with a searchable list of the apps or websites. The same controls are in a menu bar panel, and a Settings window holds profiles, the browser extension, updates and diagnostics. Follows light and dark mode.
- **Built for Long Lists**: Hundreds of apps and websites stay quick: one field searches the list and adds a website, several entries can be switched on or off or removed at once, and both lists import from and export to plain text files.
- **Changes While Connected**: The profile, the route and the apps can change while connected. On macOS 27 app changes apply within seconds; a new profile or route applies with one click on Reconnect.
- **IP Address Check**: The globe button in the window shows the public IPv4 and IPv6 addresses without and with the VPN (looked up at icanhazip.com when you open it or click Refresh), and warns when the VPN doesn't change one.
- **Automatic Updates**: Checks GitHub Releases once a day ([Sparkle](https://sparkle-project.org)) and asks before installing a new version.
- **One-Click Profile Scanner**: Automatically discovers `.ovpn` configuration profiles in your Downloads, Desktop, and Documents folders.
- **Credentials and Keychain**: Prompts for `auth-user-pass` credentials and private-key passphrases, optionally remembers them in the Keychain, and hands profiles and secrets to the tunnel with each start request rather than through the Network Extension preferences, which are stored unencrypted on disk.
- **Server-Driven Configuration**: Applies pushed routes (including split tunnels and `net_gateway` exclusions), DNS servers, search and split-DNS domains, topology, MTU, and `auth-token` reconnects.
- **Integrated CLI**: Standalone `ovpn-cli` executable for testing profile handshakes and debugging connection issues without launching the UI.

---

## Routing Modes

SemiVPN offers four routing modes, chosen in the window's **Use VPN for** menu:

| Mode | Traffic Scope | Underlying Mechanism |
| :--- | :--- | :--- |
| **All Apps** | Entire system | `NEPacketTunnelProvider` that follows the server: the default route when it pushes `redirect-gateway` (or no routes), only its pushed routes for a split-tunnel server. |
| **Selected Apps** | Only user-chosen apps | Native macOS per-app VPN via `NEAppRule`. Unselected apps route direct via standard physical interfaces. `SemiProxy` has a rule too, for the IP check; it carries no website traffic in this mode. |
| **Apps and Websites** | Chosen apps + specified domains | Native `NEAppRule` for chosen applications plus a helper rule for `SemiProxy`, routing matched Chrome domains. |
| **Websites Only** | Specified domains only | Dedicated helper `NEAppRule` for `SemiProxy`. All other system apps remain direct. |

### Per-App On-Demand Routing

Selected-app modes utilize Apple's per-app on-demand behavior: a selected app can automatically trigger the tunnel when it requires network access. When explicitly disconnected, the configuration is paused so selected apps revert to direct network routing without requiring re-authorization.

### Changing Routing While Connected

Nothing is locked while connected; changes are saved at once:

- **Apps**: the new app rules are saved into the running per-app configuration. On macOS 27 they take effect within seconds without a reconnect (tested with a test app that opens a new connection every few seconds: switching it on, off and removing it each took 1–4 seconds). Apple's DTS said in 2022 that earlier versions apply app rules only when the tunnel restarts, so there SemiVPN shows **Reconnect** instead.
- **Profile and route**: a different server or kind of VPN configuration applies when the tunnel starts again; SemiVPN shows a **Reconnect** button, which stops and restarts the tunnel in a few seconds. Until then the browser proxy and the extension keep following the running tunnel (`applied_routing.json`), so listed websites don't change routes early.
- **Websites**: go through SemiProxy rather than per-app rules and always change at once.

---

## Architecture

SemiVPN is divided into modular subsystems across the core protocol library, system extensions, companion agents, and UI:

```
┌──────────────────────────────────────────────────────────┐
│                       SemiVPN App                        │
│             (SwiftUI, Profiles, Keychain, UI)            │
└──────────────┬────────────────────────────┬──────────────┘
               │                            │
               ▼                            ▼
┌──────────────────────────────┐   ┌───────────────────────┐
│     SemiProxy Helper App     │   │ Chrome Extension MV3  │
│  (127.0.0.1 / ::1 Dual-Stack │   │ (PAC Script, UI Popup,│
│  HTTP CONNECT Proxy & API)   │   │  Host Sync, Badges)   │
└──────────────┬───────────────┘   └───────────────────────┘
               │
               ▼ (Mapped via NEAppRule)
┌──────────────────────────────────────────────────────────┐
│            TunnelProvider (System Extension)             │
│       NEPacketTunnelProvider ─── utun Network Bridge     │
│                              │                           │
│              ┌───────────────┴───────────────┐           │
│              ▼                               ▼           │
│      SwiftOpenVPNCore                   COpenVPNTLS      │
│  (Wire format, Replay, Framing)     (OpenSSL 3 Memory BIO)
└──────────────────────────────────────────────────────────┘
```

### 1. SwiftOpenVPNCore (`Sources/OpenVPNCore`)

The wire-protocol engine written from scratch against OpenVPN 2.6/2.7 specifications:
- **Transport Layer**: UDP and TCP support (`proto tcp`, uint16 length-prefixed framing, partial packet buffering).
- **Control Channel**: TLS 1.2 and 1.3 through an OpenSSL memory-BIO abstraction layer; `tls-cipher` and `tls-ciphersuites` read like OpenVPN reads them (IANA names such as `TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256` become OpenSSL names, which also work); `tls-auth` (any `auth` digest, SHA1 by default, all `key-direction` modes), `tls-crypt`, `tls-crypt-v2` and dynamic tls-crypt for renegotiations; a reliable layer with a six-packet send window, OpenVPN-style acknowledgements and replay protection of wrapped packets.
- **Key Exchange**: `key_method_2` (length-prefixed strings), RFC 5705 Exported Keying Material (EKM) for OpenVPN 2.7 layouts, and classic PRF for 2.4/2.5 server layouts.
- **Data Channel**: AEAD AES-GCM and AES-CBC + HMAC framing, sliding-window replay protection (default window 64, honoring custom `replay-window` directives), keepalive ping/pong, and the OpenVPN 2.7 **AEAD-epoch** format (8-byte epoch packet-id, ciphertext-then-tag layout, `OVPN-Expand-Label` keys) when negotiated via `protocol-flags ... aead-epoch`.
- **Push Option Parsing**: `PUSH_REPLY` directives including continuations (cipher, ifconfig and topology, `route`/`route-ipv6`, `redirect-gateway`, `dns` and `dhcp-option` DNS/DOMAIN, tun-mtu, peer-id, protocol-flags, reneg-sec, auth-token, block-ipv6), plus AUTH_FAILED (incl. TEMP), AUTH_PENDING, RESTART, HALT, EXIT and INFO messages.
- **Peer Verification**: Strict enforcement of `remote-cert-tls` (key usage plus serverAuth EKU) and `verify-x509-name` (subject in OpenVPN's format, name, name-prefix) prior to transmitting plaintext data. CA trust chains (including multi-cert bundles) are validated via OpenSSL; client certificate chains (`<cert>` bundles, `extra-certs`) and passphrase-protected keys are supported.
- **Renegotiation**: In-band key renegotiation (soft reset on a new key-id) initiated by either side on `reneg-sec`, AEAD usage limits or packet-id exhaustion, with the previous key kept for in-flight packets; aead-epoch keys follow the peer's epoch rotation.
- **Resilient Reconnection**: `hand-window` timeouts, failover across remotes and resolved addresses (`remote-random`, `<connection>` blocks), cached server addresses when DNS is unavailable, exponential backoff, and permanent failures (authentication, certificates, HALT) reported instead of retried.

### 2. COpenVPNTLS (`Sources/COpenVPNTLS`)

Minimal C shim interfacing directly with OpenSSL 3:
- Memory BIOs for zero-socket, purely in-memory TLS handshakes.
- TLS 1.2 and TLS 1.3 protocol handling.
- RFC 5705 key exporter callbacks for EKM.
- Peer certificate inspection and X.509 chain verification.

### 3. TunnelProvider (`TunnelProvider/`)

A macOS Network Extension (`NEPacketTunnelProvider`), packaged as a **system extension** (`Contents/Library/SystemExtensions/com.semivpn.app.TunnelProvider.systemextension`):
- Runs as root. The app installs it with `OSSystemExtensionRequest` at launch (the first time, macOS asks the user to allow it in System Settings → General → Login Items & Extensions) and replaces it after an app update.
- Receives the profile and credentials in the options of each start the app requests, and keeps them in a root-only file in its container for on-demand starts. Credentials the user did not ask to remember are not stored, and a password the server rejects is removed.
- Logs to the unified log: `log stream --predicate 'subsystem == "com.semivpn.tunnel"'`.
- Connects the system virtual network interface (`utun`) to `SwiftOpenVPNCore`.
- Configures routes, the tunnel address (subnet and net30/p2p topologies), DNS servers, search and split-DNS domains from the push, and sizes the MTU so encrypted packets fit the physical link.
- Rebinds the transport when the physical network changes (NWPathMonitor) and after wake.
- Interacts with `NETunnelProviderManager` to enforce system-wide or per-app routing rules.

### 4. SemiProxy Helper (`ProxyHelper/`)

An embedded accessory application (`com.semivpn.proxy`):
- Runs in the background as an `LSUIElement` (no Dock icon, no bouncing).
- Registered with LaunchServices via `LSRegisterURL` so macOS Network Extension Connection Policies (NECP) accurately associate the bundle identifier with `NEAppRule` across system reboots.
- Listens dual-stack on loopback (`127.0.0.1` and `::1`) on port `49280` (HTTP CONNECT proxy) and port `49281` (local control and domain synchronization API).
- Includes parent-process watchdog monitoring (`kill(parentPID, 0)`) to terminate cleanly when SemiVPN exits.
- Refuses hosts that are not in the domain list. While the VPN is disconnected, listed domains connect directly by default, or are refused when "Block listed domains while the VPN is disconnected" is enabled (fail-closed).
- Its control API only accepts loopback `Host` headers and the SemiVPN extension's pinned origin.
- `SemiProxy --public-ip --output <file>` writes the public IPv4 and IPv6 addresses its traffic shows and exits: the app launches it for the IP check's addresses with the VPN. It must start through LaunchServices like the running helper; macOS attributes a process the app spawns itself to the app, which the per-app rules don't route.

### 5. SemiVPN App (`App/`)

A SwiftUI app with one window, a menu bar panel and a Settings window, all driven by one shared model (`AppModel`):
- The connection, the profile and the routing mode, with Reconnect for changes made while connected.
- A searchable list of the apps or websites that use the VPN, with bulk changes and plain-text import and export.
- Settings: login item, fail-closed websites, updates, logging, profile management with credential prompts and a `.ovpn` scanner, the browser extension, and diagnostics with Repair VPN Routing.
- Updates through Sparkle from GitHub Releases.

---

## Chrome Companion Extension

Located in `ChromeExtension/`, this Manifest V3 extension enables domain-based split tunneling in Google Chrome and other Chromium browsers (Edge, Brave, Vivaldi, Opera, Arc):

- **PAC Routing**: Automatically manages Chrome's proxy settings via a dynamic PAC (Proxy Auto-Config) script. Listed domains route to `127.0.0.1:49280`, while all other traffic goes `DIRECT`.
- **Instant Cache-First UI**: Rendered instantly using cached rules and connection states with asynchronous background revalidation.
- **On-The-Fly Detection**: Detects the active tab's domain and lets you add it, specify all-subdomains or exact-domain-plus-www scope, or pause/resume routing with one click.
- **Status Badges**: Real-time toolbar icon badges reflecting domain routing state (`ON`, `OFF`, `DISC`, `BLK`), `!` when the VPN is up but the site does not go through it (see Per-App Rule Cache below), and `UPD` when the extension needs a manual update.
- **Update Prompts**: The app installs each new extension build into the folder the browser loads it from. A browser runs it after one click on Reload on its Extensions page (an unpacked extension cannot reload its own files); until then the popup, the `UPD` badge, a notice in the app's window and a notification point there.
- **Disconnected Behavior**: Listed domains connect directly while the VPN is down (default), or are blocked when the app's fail-closed option is on; in that mode the PAC has no `DIRECT` fallback. Non-browser routing modes get an all-`DIRECT` PAC script. See [ChromeExtension/README.md](ChromeExtension/README.md).

### Loading the Extension

Chrome on macOS only installs extensions from the Chrome Web Store (or by policy on managed Macs), so the extension is loaded unpacked once per browser profile. In SemiVPN's **Settings → Browser** (the window's Websites list links there), choose **Set up in Google Chrome…** (or another installed browser) and follow the three steps: open the Extensions page, turn on **Developer mode**, then drag the SemiVPN folder onto the page (or **Load unpacked** with the copied path, `~/Library/Application Support/SemiVPN/ChromeExtension`). The sheet completes when the extension first checks in, and Settings → Browser lists every browser profile running it.

After a SemiVPN update, one click on the extension's Reload button (SemiVPN opens its entry on the Extensions page) loads the new version. A browser that runs the extension from another folder (for example the project's `ChromeExtension/` directory during development) does not see the app's copy; SemiVPN then shows the folder to load instead.

---

## CLI Tool (`ovpn-cli`)

For headless environments, debugging, or rapid profile verification, SemiVPN includes a standalone CLI:

```sh
swift run -c release ovpn-cli "path/to/profile.ovpn" [options]
```

### Options

| Option | Description |
| :--- | :--- |
| `--timeout <seconds>` | Give up if the tunnel is not ready in time (default: 60) |
| `--hold <seconds>` | Stay connected this long after the tunnel is ready, then disconnect (default: exit as soon as it is ready) |
| `--auth-user-pass <user> <pass>` | Provide username and password directly via the CLI |
| `--auth-file <path>` | Read the username (line 1) and password (line 2) from a file |
| `--no-ekm` | Force classic PRF key derivation even if the server supports EKM |
| `--verbose` | Log control-channel message contents |
| `--trace` / `--dump <path>` | Print every wire packet / append full hex dumps to a file |

Exit status: `0` ready (or held successfully), `1` failed, `2` usage error, `3` timeout.

### Integration Tests

`Scripts/integration-tests.sh` runs `ovpn-cli` against a real OpenVPN server
(`brew install openvpn`). The server runs unprivileged on loopback with
`dev null`, and a throwaway PKI is generated for every run:

```sh
Scripts/integration-tests.sh            # all scenarios
Scripts/integration-tests.sh tls-auth   # scenarios whose name contains "tls-auth"
KEEP_WORK=1 Scripts/integration-tests.sh reneg   # keep client/server logs
```

`Scripts/proxy-tests.sh` builds SemiProxy unsigned and tests the browser
proxy and its control API on scratch ports with a scratch configuration
(`SEMIVPN_CONTAINER`, `SEMIVPN_EXTENSION_DIR`, `SEMIVPN_PROXY_PORT`,
`SEMIVPN_CONTROL_PORT`), so a running SemiVPN is not affected.

`node Scripts/extension-tests.mjs` (Node 18+) tests the extension's update
logic (build reports, reloading into a new build, the manual-update
fallback) against a mocked `chrome` API.

---

## Building and Installation

### Prerequisites

- **macOS 14.0 (Sonoma)** or later
- **Xcode 15.0** or later
- **XcodeGen**: `brew install xcodegen`
- **OpenSSL 3**: `brew install openssl@3` (found automatically on Apple Silicon and Intel; set `OPENSSL_ROOT` for another location)
- A paid **Apple Developer Program** membership, individual or organization, signed in to Xcode (Settings → Accounts). Free personal teams cannot sign Network Extensions.

The signing team is `DEVELOPMENT_TEAM` in `project.yml`, the maintainer's team that owns the `com.semivpn.*` bundle IDs. To build with your own team, run `DEVELOPMENT_TEAM=YOUR_TEAM_ID ./Scripts/build-dev.sh` and change the bundle identifiers in `project.yml`, because a bundle ID can belong to only one team.

### One-Step Build & Install

The recommended build workflow utilizes the automated development script:

```sh
# Build, code-sign, verify, and install to /Applications/SemiVPN.app
./Scripts/build-dev.sh --install

# Build and verify only (without modifying /Applications)
./Scripts/build-dev.sh
```

This script:
1. Generates the Xcode project via `xcodegen`.
2. Builds `SemiVPN.app` with the `com.semivpn.app.TunnelProvider` system extension and `SemiProxy.app`, with a new build number (`BUILD_NUMBER`, default the Unix time).
3. Stages and bundles OpenSSL 3 dylibs using `@rpath` addressing for self-contained execution.
4. Signs all targets with your Apple Development identity and entitlements.
5. Verifies code signatures and entitlements, installs to `/Applications` (system extensions only install from there) and registers `SemiProxy` with `lsregister`.

On first launch SemiVPN asks macOS to install its network extension; allow it in **System Settings → General → Login Items & Extensions → Network Extensions**. Later builds replace it without asking.

### Manual Xcode Build

```sh
# 1. Generate the Xcode project
xcodegen generate

# 2. Build via xcodebuild
xcodebuild \
  -project semi-vpn.xcodeproj \
  -scheme semi-vpn \
  -configuration Debug \
  -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  build
```

> [!NOTE]
> Network Extension development on macOS requires code signing with an active Apple Developer Team. Ad-hoc signing or `CODE_SIGNING_ALLOWED=NO` will prevent macOS from activating the `NEPacketTunnelProvider`.

### Running Unit Tests

The core wire-format protocol engine and crypto components include an extensive test suite that runs independently without Xcode or code signing:

```sh
swift test
```

Executes 71 unit tests covering:
- tls-auth known-answer vectors captured from a real OpenVPN server, tls-crypt and tls-crypt-v2, dynamic tls-crypt keys
- AEAD-epoch key derivation, packet round-trips and epoch rotation
- OpenVPN PRF and RFC 5705 EKM vector verification
- Sliding-window replay filter state transitions
- TCP packet framing, buffering, and fragmentation
- Profile parsing (protocols, remotes, quoting, file inlining, unsupported features) and `PUSH_REPLY`/control-message parsing

End-to-end tests (see [Integration Tests](#integration-tests)) connect `ovpn-cli` to a real OpenVPN server in 54 scenarios, `Scripts/proxy-tests.sh` tests the browser proxy and its control API (18 checks) against an isolated SemiProxy instance, and `Scripts/extension-tests.mjs` tests the extension's self-update logic.

`Scripts/ui-snapshots.sh` renders every screen with sample data (150 websites, 40 apps), in light and dark mode, into `.build/ui-snapshots` from the Debug build, without touching a running SemiVPN.

---

## Repository Layout

```
├── App/                      # Main SwiftUI application and state managers
│   ├── AppModel.swift        # State and actions shared by the window, menu bar and Settings
│   ├── MainPanel.swift       # The window, the menu bar panel and the app/website lists
│   ├── MenuBar.swift         # Menu bar item and its panel
│   ├── SettingsView.swift    # Settings window (General, Profiles, Browser, Diagnostics)
│   ├── AppUpdater.swift      # Sparkle updates from GitHub Releases
│   ├── UISnapshots.swift     # Debug-only rendering of the screens with sample data
│   ├── VPNManager.swift      # NETunnelProviderManager controller
│   ├── ChromeExtensionInstaller.swift # Extension folder, browsers, Extensions page
│   ├── ExtensionMonitor.swift # Which browsers run which extension build
│   ├── BrowserExtensionPanel.swift # Extension status, setup guide, update steps
│   └── LocalProxyServer.swift# HTTP CONNECT loopback proxy core
├── ChromeExtension/          # Chrome Manifest V3 companion extension
├── Package.swift             # Swift Package Manager manifest for core libraries
├── project.yml               # XcodeGen project definition specification
├── ProxyHelper/              # Embedded SemiProxy background accessory agent
│   └── main.swift            # LaunchServices runner and watchdog lifecycle
├── Scripts/                  # Development, signing, test and installation scripts
│   ├── build-dev.sh          # Automated build, sign, verify & install pipeline
│   ├── integration-tests.sh  # ovpn-cli against a real OpenVPN server
│   ├── proxy-tests.sh        # SemiProxy and its control API in isolation
│   ├── extension-tests.mjs   # Extension update logic with a mocked chrome API
│   ├── stamp-extension.sh    # Stamps the bundled extension's build fingerprint
│   ├── notarize.sh           # Submits a build to Apple's notary service
│   ├── make-dmg.sh           # Installer DMG layout (Packaging/dmg)
│   ├── sparkle-sign.sh       # Signs Sparkle's helpers with the app's identity
│   ├── verify-update-signature.swift # Checks an update against the app's key
│   ├── ui-snapshots.sh       # Renders the screens for design review
│   └── openssl-*.sh          # Locate, stage and bundle OpenSSL for Xcode
├── Shared/                   # Shared configurations and data models
│   ├── SharedConfig.swift    # Routing modes, domain models, and IPC constants
│   ├── BrowserExtension.swift # Extension folder, build IDs and browser reports
│   ├── RoutingListFile.swift # Text format for importing and exporting the lists
│   └── TunnelSecrets.swift   # Keychain hand-off of profiles and credentials
├── Sources/
│   ├── COpenVPNTLS/          # C OpenSSL 3 shim (memory BIOs, TLS session exporter)
│   ├── OpenVPNCore/          # Pure Swift OpenVPN 2.6/2.7 protocol implementation
│   └── OpenVPNCLI/           # Headless ovpn-cli profile test executable
├── Tests/
│   └── OpenVPNCoreTests/     # Unit tests for protocol wire formats, crypto, and framing
├── TestApps/                 # Semi Test A/B/C: show and log the public IP their traffic uses
└── TunnelProvider/           # NEPacketTunnelProvider system extension
```

---

## Verified Compatibility

SemiVPN has been validated byte-for-byte against:
- **Commercial VPN Providers**: Verified with TLS 1.3 / AES-128-GCM / tls-crypt-v2, full AEAD-epoch data channel, and bidirectional live keepalive round-trips.
- **OpenVPN 2.7.x Servers**: Tested against OpenVPN 2.7.6 with tls-crypt-v2 and AEAD-epoch negotiation.
- **OpenVPN 2.6.x Servers**: Tested against OpenVPN 2.6.x with tls-auth (SHA-512) and AES-256-CBC, verified byte-for-byte against the server's logged epoch keys.
- **OpenVPN 2.7.7 (automated)**: `Scripts/integration-tests.sh` covers UDP/TCP, tls-auth (SHA1/SHA256/SHA512, all key directions), tls-crypt, tls-crypt-v2, credentials, AUTH_FAILED/AUTH_PENDING/auth-token, server RESTART/HALT/EXIT, push continuation, certificate chains, encrypted keys, `verify-x509-name`, and in-band renegotiation.

---

## Known Limitations

- **Per-App VPN Deployment**: macOS enforces MDM/configuration-profile requirements for production deployment of `NEAppRule`. Development builds use Apple's `NETestAppMapping` mechanism.
- **IPv6 Dual-Stack & Leak Protection**: SemiVPN supports dual-stack IPv6 tunneling when configured on the OpenVPN server (parsing `ifconfig-ipv6`, `route-ipv6`, `redirect-gateway ipv6`, and IPv6 DNS). When connected to an IPv4-only VPN on a dual-stack network, SemiVPN automatically activates IPv6 Leak Protection by capturing all IPv6 traffic in the tunnel and synthesizing ICMPv6 Destination Unreachable responses, causing Happy Eyeballs (RFC 8305) to immediately route all traffic through the VPN's IPv4 tunnel without leaking to the local ISP.
- **UDP / QUIC in Browser Routing**: The browser proxy handles TCP HTTP and HTTPS CONNECT traffic. UDP-based protocols (QUIC/HTTP3 and WebRTC) should be disabled in Chrome if strict privacy isolation is required.
- **Per-App Rule Cache**: macOS's VPN service (`nesessionmanager`) resolves each per-app rule to the executables it matches once and keeps that until it restarts. After an update that changes SemiProxy's executable, the rule can stop matching it, and browser traffic would leave outside the VPN. The cache lives in `/Library/Preferences/com.apple.networkextension.uuidcache.plist` and survives restarts. `build-dev.sh` gives every build a new build number. SemiProxy detects a stale rule (the extension shows `!`, or `BLK` in fail-closed mode, and refuses listed sites in that mode), and SemiVPN offers **Repair VPN Routing…**, which removes that cache file and restarts the service with your administrator password.
- **Browser Proxy Lifetime**: SemiProxy runs while the SemiVPN app runs (it is a menu-bar app and can start at login). If the app is quit, Chrome falls back to DIRECT for listed domains unless the fail-closed option is enabled.
- **Unsupported Profile Features**: bridged `dev tap`, static-key (`secret`) mode, `pkcs12`/PKCS#11/`cryptoapicert` keys, `http-proxy`/`socks-proxy`, `fragment`, compression (only stubs are announced), `PUSH_UPDATE` and `crl-verify`. Importing a profile reports these.

---

## Distribution & Signing

`TunnelProvider` is packaged as a Network Extension **system extension**, the packaging Apple requires for distribution outside the Mac App Store ([TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)):

- **Development builds** (`build-dev.sh`, Apple Development signing) run on the Macs registered to the signing team and use the `packet-tunnel-provider` entitlement value.
- **Developer ID (outside the App Store)**: available to individual and organization memberships. The Release configuration uses `packet-tunnel-provider-systemextension`, which Developer ID requires; sign the app and the extension with a Developer ID Application certificate and Developer ID provisioning profiles that include the Network Extensions and System Extension capabilities, then notarize.
- **Mac App Store**: App Review Guideline 5.4 allows VPN apps only from developers **enrolled as an organization**.

Releases are built, signed with Developer ID, notarized and published as a draft GitHub release by the manually started **Release** workflow. Publishing a release starts the **Appcast** workflow, which signs its DMG with the update key and attaches `appcast.xml`, the feed installed copies check; see [docs/RELEASING.md](docs/RELEASING.md) for the one-time certificate, profile, update key and secret setup.

All targets build with the Hardened Runtime, which notarization requires.

---

## License

This project is licensed under the [MIT License](LICENSE).

### Third-Party Acknowledgments
- **OpenSSL**: Licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). SemiVPN links against OpenSSL 3 for cryptographic primitives and TLS memory BIOs.
- **Sparkle**: Licensed under the [MIT License](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE). SemiVPN uses Sparkle 2 for updates.
