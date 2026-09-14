# SemiVPN

[![macOS](https://img.shields.io/badge/macOS-14.0%2B%20%28Sonoma%29-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%20%2F%206.0-orange?logo=swift)](https://swift.org)
[![NetworkExtension](https://img.shields.io/badge/Framework-NetworkExtension-blue)](https://developer.apple.com/documentation/networkextension)
[![OpenVPN](https://img.shields.io/badge/Protocol-OpenVPN%202.6%20%2F%202.7-brightgreen)](https://openvpn.net/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/Tests-38%20passing-success)](Tests/)

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
- **Keychain-Backed Security**: Encrypted storage for VPN credentials and profile certificates with seamless migration fallbacks.
- **Integrated CLI**: Standalone `ovpn-cli` executable for testing profile handshakes and debugging connection issues without launching the UI.

---

## Routing Modes

SemiVPN offers four distinct routing modes configured directly from the **Routing** workspace:

| Mode | Traffic Scope | Underlying Mechanism |
| :--- | :--- | :--- |
| **All apps** | Entire system | Full tunnel `NEPacketTunnelProvider` setting the default IPv4 route (`0.0.0.0/0`). |
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
- **Control Channel**: TLS 1.2 and 1.3 through an OpenSSL memory-BIO abstraction layer, `tls-auth` (profile digest, 2.7 static-key layout), and `tls-crypt-v2` packet wrapping with reliable retransmission and LRU acknowledgments.
- **Key Exchange**: `key_method_2` (length-prefixed strings), RFC 5705 Exported Keying Material (EKM) for OpenVPN 2.7 layouts, and classic PRF for 2.4/2.5 server layouts.
- **Data Channel**: AEAD AES-GCM and AES-CBC + HMAC framing, sliding-window replay protection (default window 64, honoring custom `replay-window` directives), keepalive ping/pong, and the OpenVPN 2.7 **AEAD-epoch** format (8-byte epoch packet-id, ciphertext-then-tag layout, `OVPN-Expand-Label` keys) when negotiated via `protocol-flags ... aead-epoch`.
- **Push Option Parsing**: Full parser for server `PUSH_REPLY` directives (cipher, ifconfig, route-gateway, topology, DNS servers, EKM, peer-id, aead-epoch, reneg-sec).
- **Peer Verification**: Strict enforcement of `remote-cert-tls` (serverAuth EKU) and `verify-x509-name` (commonName, name-prefix, subject) prior to transmitting plaintext data. CA trust chains (including multi-cert bundles) are validated via OpenSSL.
- **Resilient Reconnection**: PUSH_REQUEST retry loops, exponential backoff on transient network failures, automatic session refresh on server soft-resets / `reneg-sec`, and proactive re-keying before the 32-bit data packet counter exhausts.

### 2. COpenVPNTLS (`Sources/COpenVPNTLS`)

Minimal C shim interfacing directly with OpenSSL 3:
- Memory BIOs for zero-socket, purely in-memory TLS handshakes.
- TLS 1.2 and TLS 1.3 protocol handling.
- RFC 5705 key exporter callbacks for EKM.
- Peer certificate inspection and X.509 chain verification.

### 3. TunnelProvider (`TunnelProvider/`)

A macOS Network Extension (`NEPacketTunnelProvider`):
- Connects the system virtual network interface (`utun`) to `SwiftOpenVPNCore`.
- Dynamically configures IP routing, MTU, DNS servers, and search domains received from server push options.
- Interacts with `NETunnelProviderManager` to enforce system-wide or per-app routing rules.

### 4. SemiProxy Helper (`ProxyHelper/`)

An embedded accessory application (`com.semivpn.proxy`):
- Runs in the background as an `LSUIElement` (no Dock icon, no bouncing).
- Registered with LaunchServices via `LSRegisterURL` so macOS Network Extension Connection Policies (NECP) accurately associate the bundle identifier with `NEAppRule` across system reboots.
- Listens dual-stack on loopback (`127.0.0.1` and `::1`) on port `49280` (HTTP CONNECT proxy) and port `49281` (local control and domain synchronization API).
- Includes parent-process watchdog monitoring (`kill(parentPID, 0)`) to terminate cleanly when SemiVPN exits.
- Features a fail-closed architecture: non-listed domains or requests made while disconnected are immediately rejected with a 12-second upstream connect timeout.

### 5. SemiVPN App (`App/`)

A SwiftUI management console featuring:
- Profile management with credential prompts and automatic `.ovpn` scanner.
- 4-mode routing selector and application picker.
- Browser domain rule manager with subdomain toggling.
- Diagnostics view displaying connection logs, tunnel status, and proxy health.

---

## Chrome Companion Extension

Located in `ChromeExtension/`, this Manifest V3 extension enables seamless domain-based split tunneling in Google Chrome:

- **PAC Routing**: Automatically manages Chrome's proxy settings via a dynamic PAC (Proxy Auto-Config) script. Listed domains route to `127.0.0.1:49280`, while all other traffic goes `DIRECT`.
- **Instant Cache-First UI**: Rendered instantly using cached rules and connection states with asynchronous background revalidation.
- **On-The-Fly Detection**: Detects the active tab's domain and lets you add it, specify all-subdomains or exact-domain-plus-www scope, or pause/resume routing with one click.
- **Status Badges**: Real-time toolbar icon badges reflecting domain routing state (`ON`, `OFF`, `DISC`).
- **Fail-Closed Protection**: If SemiVPN is disconnected or a non-browser routing mode is active, the extension automatically sets an all-`DIRECT` PAC script.

### Loading the Extension

1. In SemiVPN, open the **Browser** workspace and click **Prepare** (or copy `ChromeExtension/` to a permanent location).
2. In Google Chrome, navigate to `chrome://extensions/`.
3. Enable **Developer mode** in the top-right corner.
4. Click **Load unpacked** and select the prepared extension folder (`~/Library/Application Support/SemiVPN/ChromeExtension` or the project's `ChromeExtension/` directory).

---

## CLI Tool (`ovpn-cli`)

For headless environments, debugging, or rapid profile verification, SemiVPN includes a standalone CLI:

```sh
swift run -c release ovpn-cli "path/to/profile.ovpn" [options]
```

### Options

| Option | Description |
| :--- | :--- |
| `--timeout <seconds>` | Connection timeout in seconds (default: 30) |
| `--no-ekm` | Force classic PRF key derivation even if the server supports EKM |
| `--auth-user-pass <user> <pass>` | Provide username and password directly via the CLI |

---

## Building and Installation

### Prerequisites

- **macOS 14.0 (Sonoma)** or later
- **Xcode 15.0** or later
- **XcodeGen**: `brew install xcodegen`
- **OpenSSL 3**: `brew install openssl@3`
- An **Apple Developer Account** (for signing Network Extensions)

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

Executes 38 unit tests covering:
- TLS-Auth and TLS-Crypt-V2 wrapping/unwrapping
- AEAD-Epoch key derivation and packet round-trips
- OpenVPN PRF and RFC 5705 EKM vector verification
- Sliding-window replay filter state transitions
- TCP packet framing, buffering, and fragmentation
- `PUSH_REPLY` directive and options parsing

---

## Repository Layout

```
├── App/                      # Main SwiftUI application and state managers
│   ├── ContentView.swift     # 5-section workspace UI (Overview, Routing, Browser, etc.)
│   ├── VPNManager.swift      # NETunnelProviderManager controller
│   ├── ChromeExtensionInstaller.swift # Extension staging and sync manager
│   └── LocalProxyServer.swift# HTTP CONNECT loopback proxy core
├── ChromeExtension/          # Chrome Manifest V3 companion extension
├── Development/              # Local development configurations and scratch files
├── Package.swift             # Swift Package Manager manifest for core libraries
├── project.yml               # XcodeGen project definition specification
├── ProxyHelper/              # Embedded SemiProxy background accessory agent
│   └── main.swift            # LaunchServices runner and watchdog lifecycle
├── Scripts/                  # Development, signing, and installation scripts
│   └── build-dev.sh          # Automated build, sign, verify & install pipeline
├── Shared/                   # Shared configurations and data models
│   └── SharedConfig.swift    # Routing modes, domain models, and IPC constants
├── Sources/
│   ├── COpenVPNTLS/          # C OpenSSL 3 shim (memory BIOs, TLS session exporter)
│   ├── OpenVPNCore/          # Pure Swift OpenVPN 2.6/2.7 protocol implementation
│   └── OpenVPNCLI/           # Headless ovpn-cli profile test executable
├── Tests/
│   └── OpenVPNCoreTests/     # Unit tests for protocol wire formats, crypto, and framing
└── TunnelProvider/           # NEPacketTunnelProvider macOS system extension
```

---

## Verified Compatibility

SemiVPN has been validated byte-for-byte against:
- **Commercial VPN Providers**: Verified with TLS 1.3 / AES-128-GCM / tls-crypt-v2, full AEAD-epoch data channel, and bidirectional live keepalive round-trips.
- **OpenVPN 2.7.x Servers**: Tested against OpenVPN 2.7.6 with tls-crypt-v2 and AEAD-epoch negotiation.
- **OpenVPN 2.6.x Servers**: Tested against OpenVPN 2.6.x with tls-auth (SHA-512) and AES-256-CBC, verified byte-for-byte against the server's logged epoch keys.

---

## Known Limitations

- **Per-App VPN Deployment**: macOS enforces MDM/configuration-profile requirements for production deployment of `NEAppRule`. Development builds use Apple's `NETestAppMapping` mechanism.
- **Session Renegotiation**: Server soft-resets and `reneg-sec` triggers are handled via seamless session re-establishment rather than in-band rekeying. Session packet counters are proactively refreshed before counter overflow.
- **IPv6 Tunneling**: The current tunnel configuration prioritizes IPv4 routes; IPv6 tunnel configuration is planned for a subsequent update.
- **UDP / QUIC in Browser Routing**: The browser proxy handles TCP HTTP and HTTPS CONNECT traffic. UDP-based protocols (QUIC/HTTP3 and WebRTC) should be disabled in Chrome if strict privacy isolation is required.
- **TAP Devices**: Routed IP (`dev tun`) mode is supported; bridged ethernet (`dev tap`) is unsupported.

---

## Distribution & Signing

To distribute SemiVPN outside a development environment:
1. Sign both the host application and `TunnelProvider.appex` with a valid Apple Developer ID Application certificate.
2. Enable the Hardened Runtime (`ENABLE_HARDENED_RUNTIME=YES`).
3. Submit the build for Apple Notarization via `xcrun notarytool submit`.
4. Pre-approve system extensions via MDM (`NEProviderSystemExtensionPolicy` payload) or prompt the user for local system extension approval.

---

## License

This project is licensed under the [MIT License](LICENSE).

### Third-Party Acknowledgments
- **OpenSSL**: Licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). SemiVPN links against OpenSSL 3 for cryptographic primitives and TLS memory BIOs.
