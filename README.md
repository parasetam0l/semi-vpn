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
- **Modern SwiftUI Interface**: Clean dark-mode workspace organized into Overview, Routing, Browser, Profiles, and Diagnostics sections.
- **One-Click Profile Scanner**: Automatically discovers `.ovpn` configuration profiles in your Downloads, Desktop, and Documents folders.
- **Credentials and Keychain**: Prompts for `auth-user-pass` credentials and private-key passphrases, optionally remembers them in the Keychain, and hands profiles and secrets to the tunnel through a shared Keychain access group rather than the Network Extension preferences.
- **Server-Driven Configuration**: Applies pushed routes (including split tunnels and `net_gateway` exclusions), DNS servers, search and split-DNS domains, topology, MTU, and `auth-token` reconnects.
- **Integrated CLI**: Standalone `ovpn-cli` executable for testing profile handshakes and debugging connection issues without launching the UI.

---

## Routing Modes

SemiVPN offers four distinct routing modes configured directly from the **Routing** workspace:

| Mode | Traffic Scope | Underlying Mechanism |
| :--- | :--- | :--- |
| **All apps** | Entire system | `NEPacketTunnelProvider` that follows the server: the default route when it pushes `redirect-gateway` (or no routes), only its pushed routes for a split-tunnel server. |
| **Selected apps only** | Only user-chosen apps | Native macOS per-app VPN via `NEAppRule`. Unselected apps route direct via standard physical interfaces. |
| **Selected apps + browser** | Chosen apps + specified domains | Native `NEAppRule` for chosen applications plus a helper rule for `SemiProxy`, routing matched Chrome domains. |
| **Browser only** | Specified domains only | Dedicated helper `NEAppRule` for `SemiProxy`. All other system apps remain direct. |

### Per-App On-Demand Routing

Selected-app modes utilize Apple's per-app on-demand behavior: a selected app can automatically trigger the tunnel when it requires network access. When explicitly disconnected, the configuration is paused so selected apps revert to direct network routing without requiring re-authorization.

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
│              TunnelProvider (App Extension)              │
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
- **Control Channel**: TLS 1.2 and 1.3 through an OpenSSL memory-BIO abstraction layer; `tls-auth` (any `auth` digest, SHA1 by default, all `key-direction` modes), `tls-crypt`, `tls-crypt-v2` and dynamic tls-crypt for renegotiations; a reliable layer with a six-packet send window, OpenVPN-style acknowledgements and replay protection of wrapped packets.
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

A macOS Network Extension (`NEPacketTunnelProvider`):
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

### 5. SemiVPN App (`App/`)

A SwiftUI management console featuring:
- Profile management with credential prompts and automatic `.ovpn` scanner.
- 4-mode routing selector and application picker.
- Browser domain rule manager with subdomain toggling.
- Diagnostics view displaying connection logs, tunnel status, and proxy health.

---

## Chrome Companion Extension

Located in `ChromeExtension/`, this Manifest V3 extension enables domain-based split tunneling in Google Chrome and other Chromium browsers (Edge, Brave, Vivaldi, Opera, Arc):

- **PAC Routing**: Automatically manages Chrome's proxy settings via a dynamic PAC (Proxy Auto-Config) script. Listed domains route to `127.0.0.1:49280`, while all other traffic goes `DIRECT`.
- **Instant Cache-First UI**: Rendered instantly using cached rules and connection states with asynchronous background revalidation.
- **On-The-Fly Detection**: Detects the active tab's domain and lets you add it, specify all-subdomains or exact-domain-plus-www scope, or pause/resume routing with one click.
- **Status Badges**: Real-time toolbar icon badges reflecting domain routing state (`ON`, `OFF`, `DISC`, `BLK`), `!` when the VPN is up but the site does not go through it (see Per-App Rule Cache below), and `UPD` when the extension needs a manual update.
- **Update Prompts**: The app installs each new extension build into the folder the browser loads it from. A browser runs it after one click on Reload on its Extensions page (an unpacked extension cannot reload its own files); until then the popup, the `UPD` badge, the app's Browser tab and a notification point there.
- **Disconnected Behavior**: Listed domains connect directly while the VPN is down (default), or are blocked when the app's fail-closed option is on; in that mode the PAC has no `DIRECT` fallback. Non-browser routing modes get an all-`DIRECT` PAC script. See [ChromeExtension/README.md](ChromeExtension/README.md).

### Loading the Extension

Chrome on macOS only installs extensions from the Chrome Web Store (or by policy on managed Macs), so the extension is loaded unpacked once per browser profile. In SemiVPN's **Browser** workspace, choose **Set up in Google Chrome…** (or another installed browser) and follow the three steps: open the Extensions page, turn on **Developer mode**, then drag the SemiVPN folder onto the page (or **Load unpacked** with the copied path, `~/Library/Application Support/SemiVPN/ChromeExtension`). The sheet completes when the extension first checks in, and the Browser workspace lists every browser profile running it.

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
2. Builds `SemiVPN.app`, `TunnelProvider.appex`, and `SemiProxy.app`.
3. Stages and bundles OpenSSL 3 dylibs using `@rpath` addressing for self-contained execution.
4. Signs all targets with your Apple Development identity and entitlements.
5. Verifies code signatures and registers `SemiProxy` with `lsregister`.

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

End-to-end tests (see [Integration Tests](#integration-tests)) connect `ovpn-cli` to a real OpenVPN server in 49 scenarios, `Scripts/proxy-tests.sh` tests the browser proxy and its control API (13 checks) against an isolated SemiProxy instance, and `Scripts/extension-tests.mjs` tests the extension's self-update logic.

---

## Repository Layout

```
├── App/                      # Main SwiftUI application and state managers
│   ├── ContentView.swift     # 5-section workspace UI (Overview, Routing, Browser, etc.)
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
│   └── openssl-*.sh          # Locate, stage and bundle OpenSSL for Xcode
├── Shared/                   # Shared configurations and data models
│   ├── SharedConfig.swift    # Routing modes, domain models, and IPC constants
│   ├── BrowserExtension.swift # Extension folder, build IDs and browser reports
│   └── TunnelSecrets.swift   # Keychain hand-off of profiles and credentials
├── Sources/
│   ├── COpenVPNTLS/          # C OpenSSL 3 shim (memory BIOs, TLS session exporter)
│   ├── OpenVPNCore/          # Pure Swift OpenVPN 2.6/2.7 protocol implementation
│   └── OpenVPNCLI/           # Headless ovpn-cli profile test executable
├── Tests/
│   └── OpenVPNCoreTests/     # Unit tests for protocol wire formats, crypto, and framing
└── TunnelProvider/           # NEPacketTunnelProvider app extension
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

`TunnelProvider` is packaged as a Network Extension **app extension** (`.appex`). macOS only accepts app-extension NE providers for development builds and Mac App Store distribution ([TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)). A development build runs only on the Macs registered to the signing team:

- **Mac App Store**: sign with App Store distribution profiles that include the `packet-tunnel-provider` entitlement and the shared keychain group, then submit through App Store Connect. App Review Guideline 5.4 allows VPN apps only from developers **enrolled as an organization**, so this route needs an organization membership.
- **Developer ID (outside the App Store)**: available to individual and organization memberships. Apple requires Network Extension providers to be packaged as a **System Extension** (`packet-tunnel-provider-systemextension`, activated with `OSSystemExtensionRequest`). That packaging is not implemented yet; the existing provider code can be reused, but the target type, entitlements and activation flow have to change before a notarized Developer ID build will work.

All targets build with the Hardened Runtime, which notarization requires.

---

## License

This project is licensed under the [MIT License](LICENSE).

### Third-Party Acknowledgments
- **OpenSSL**: Licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). SemiVPN links against OpenSSL 3 for cryptographic primitives and TLS memory BIOs.
