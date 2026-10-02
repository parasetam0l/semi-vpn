import Foundation
import Darwin

public enum ConnectionError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidProfile(String)
    case socketError(String)
    case resolveFailed(String)
    case tlsSetupFailed(String)
    case handshakeTimeout
    case pushTimeout
    case authFailed(String)
    /// `AUTH_FAILED,TEMP`: the server asks to retry later.
    case authFailedTemporary(String, backoff: Int?)
    case serverRestart(String)
    /// The server announced it is shutting down (`EXIT` / OCC exit).
    case serverExit
    case serverHalt(String)
    case unsupportedCipher(String)
    case protocolError(String)
    case keyDerivationFailed
    case disconnected

    /// Permanent errors stop the reconnect loop: retrying cannot help.
    public var isPermanent: Bool {
        switch self {
        case .invalidProfile, .authFailed, .tlsSetupFailed, .keyDerivationFailed,
             .unsupportedCipher, .serverHalt, .protocolError, .disconnected:
            return true
        case .socketError, .resolveFailed, .handshakeTimeout, .pushTimeout,
             .authFailedTemporary, .serverRestart, .serverExit:
            return false
        }
    }

    public var description: String {
        switch self {
        case .invalidProfile(let reason): return "Invalid profile: \(reason)"
        case .socketError(let reason): return "Network error: \(reason)"
        case .resolveFailed(let host): return "Cannot resolve \(host)"
        case .tlsSetupFailed(let reason): return "TLS error: \(reason)"
        case .handshakeTimeout: return "TLS handshake timed out (server unreachable or keys do not match)"
        case .pushTimeout: return "The server did not send its configuration (PUSH_REPLY)"
        case .authFailed(let reason): return reason.isEmpty ? "Authentication failed" : "Authentication failed: \(reason)"
        case .authFailedTemporary(let reason, _): return "Server temporarily rejected authentication: \(reason)"
        case .serverRestart(let reason): return reason.isEmpty ? "Server requested a reconnect" : "Server requested a reconnect: \(reason)"
        case .serverExit: return "The server is shutting down"
        case .serverHalt(let reason): return reason.isEmpty ? "The server disconnected this client" : "The server disconnected this client: \(reason)"
        case .unsupportedCipher(let cipher): return "The server selected an unsupported data cipher: \(cipher)"
        case .protocolError(let reason): return "Protocol error: \(reason)"
        case .keyDerivationFailed: return "Data-channel key derivation failed"
        case .disconnected: return "Disconnected"
        }
    }
}

/// A connected OpenVPN session.
public final class OpenVPNConnection: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case authenticating
        case derivingKeys
        case waitPush
        case ready
        case reconnecting
        case failed(String)
        case disconnected
    }

    public protocol Delegate: AnyObject {
        func connection(_ connection: OpenVPNConnection, stateChanged state: State)
        func connection(_ connection: OpenVPNConnection, didReceiveIPPacket packet: Data)
        func connection(_ connection: OpenVPNConnection, log message: String)
    }

    public static let pingString = Data([
        0x2a, 0x18, 0x7b, 0xf3, 0x64, 0x1e, 0xb4, 0xcb,
        0x07, 0xed, 0x2d, 0x0a, 0x98, 0x1f, 0xc7, 0x48,
    ])

    /// OpenVPN Configuration Control (OCC) messages travel on the data
    /// channel behind this magic (OpenVPN `occ.c`).
    static let occMagic = Data([
        0x28, 0x7f, 0x34, 0x6b, 0xd4, 0xef, 0x7a, 0x81,
        0x2d, 0x56, 0xb8, 0xd3, 0xaf, 0xc5, 0x45, 0x9c,
    ])
    static let occExit: UInt8 = 6

    /// Connection state. Mutated only on the connection queue, but read
    /// from any thread (CLI, UI) — guarded so the enum read cannot tear.
    public private(set) var state: State {
        get { lock.withLock { _state } }
        set {
            lock.withLock { _state = newValue }
            delegate?.connection(self, stateChanged: newValue)
        }
    }
    private var _state: State = .idle
    private let lock = NSLock()

    /// Optional raw wire-packet observer for diagnostics. Called on the
    /// connection queue.
    public var packetObserver: ((Bool, Data) -> Void)?

    public let profile: OVPNProfile
    public weak var delegate: Delegate?

    /// When true, data-channel keys are derived via the RFC 5705 exporter
    /// (requires the server to push `key-derivation tls-ekm`).
    public var preferTLSKeyExport = true

    /// The interface the transport socket binds to (e.g. "en0"). Required
    /// when the tunnel itself becomes the default route: the transport must
    /// not route through itself. Safe to set from any thread; applies to
    /// the next transport.
    public var bindInterfaceName: String? {
        get { lock.withLock { _bindInterfaceName } }
        set { lock.withLock { _bindInterfaceName = newValue } }
    }
    private var _bindInterfaceName: String?

    public private(set) var negotiatedCipher: OVPNProfile.Cipher
    public private(set) var negotiatedDigest: OVPNProfile.Digest
    public private(set) var peerID: UInt32 = 0

    /// The options pushed for the current session (nil until ready). Safe
    /// to read from any thread.
    public private(set) var pushedOptions: PushedOptions? {
        get { lock.withLock { _pushedOptions } }
        set { lock.withLock { _pushedOptions = newValue } }
    }
    private var _pushedOptions: PushedOptions?

    /// Indicates whether the active connection session negotiated an IPv6 configuration.
    public var hasVPNIPv6: Bool {
        if let pushed = pushedOptions {
            if pushed.blockIPv6 { return false }
            if pushed.ifconfigIPv6Local != nil { return true }
        }
        return profile.ifconfigIPv6Local != nil
    }

    /// The remote currently in use (for diagnostics and settings).
    public var currentRemote: OVPNProfile.Remote? {
        lock.withLock { _currentRemote }
    }
    private var _currentRemote: OVPNProfile.Remote?

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    /// All connection state is confined to this serial queue; callers of
    /// the public API (packet flow, UI) hop onto it.
    private let queue = DispatchQueue(label: "com.semivpn.OpenVPNConnection", qos: .userInitiated)

    /// The transport of the remote being connected (its own `proto`, or
    /// the profile's).
    private var activeTransport: OVPNProfile.Transport = .udp
    /// Bumped whenever the transport is torn down, so work that was in
    /// flight for an older socket (DNS results, drain loops) stops.
    private var transportGeneration: UInt64 = 0

    // TCP transport state (activeTransport == .tcp)
    private var tcpEstablished = false
    private var tcpFramer = TCPPacketFramer()   // inbound stream reassembly
    private var tcpOutbound = Data()            // packets awaiting a full socket write
    private var tcpWriteSource: DispatchSourceWrite?

    /// Session-level control-channel protection, shared by all key states.
    private var wrapper: ControlWrapper?
    private var localSessionID = Data()
    /// The key in use: key-id 0 for a new session, then the latest
    /// renegotiated key.
    private var primary: KeyState?
    /// A renegotiation in progress (soft reset on the next key-id).
    private var pending: KeyState?
    /// The previous key, still accepted for incoming data until it expires
    /// (OpenVPN's lame duck / transition window).
    private var lameDuck: KeyState?
    private var lameDuckExpiry: TimeInterval = 0
    private var nextKeyID: UInt8 = 1
    /// The peer's data format: servers that announce no DATA_V2 support use
    /// P_DATA_V1; we mirror whatever the peer sends.
    private var peerDataV1 = false
    /// Logged once per session when the first authentic data packet arrives.
    private var dataChannelVerified = false
    /// Last time an authenticated packet arrived (drives ping-restart).
    private var lastReceiveTime: TimeInterval = 0
    /// Last time a data packet (including pings) was sent.
    private var lastDataSendTime: TimeInterval = 0
    private var pingInterval: TimeInterval = 10
    private var pingRestart: TimeInterval = 60

    // Negotiation deadlines (OpenVPN hand-window): the TLS handshake and
    // key exchange must finish, and then the PUSH_REPLY arrive, in time.
    private var negotiationDeadline: TimeInterval = .infinity
    private var authPending = false

    // PUSH_REQUEST retry state (the official client re-sends it every
    // second until PUSH_REPLY; a single request is not enough on some
    // servers).
    private var lastPushRequestAt: TimeInterval = 0
    private var pushRequestAttempts = 0
    /// Options of a PUSH_REPLY split with `push-continuation 2`.
    private var pendingPushOptions: [String] = []

    /// `auth-token` pushed by the server: replaces the password on later
    /// reconnects (so one-time passwords are not reused).
    private var authToken: String?
    private var authTokenUser: String?
    private var usingAuthToken = false

    // Reconnect loop with exponential backoff and remote failover; runs
    // until disconnect().
    private var wantsConnection = false
    private var reconnectAttempt = 0
    /// Invalidates delayed reconnect closures when a newer lifecycle event
    /// has already replaced the transport.
    private var reconnectGeneration: UInt64 = 0
    /// Remotes in connection order (shuffled for `remote-random`).
    private var remoteOrder: [OVPNProfile.Remote] = []
    private var remoteIndex = 0
    /// Index into the resolved addresses of the current remote.
    private var addressIndex = 0
    private var currentAddresses: [ResolvedRemote] = []
    /// Last successful resolution per "host:port"; used when DNS is
    /// unavailable (e.g. while a full tunnel is reconnecting).
    private var resolvedCache: [String: [ResolvedRemote]] = [:]

    private var tickSource: DispatchSourceTimer?

    /// Logs control-message contents when enabled (off in production).
    public var verboseLogging = false

    static let maxPushRequestAttempts = 10
    static let defaultHandWindow: TimeInterval = 60
    /// OpenVPN's default `reneg-sec`: renegotiate the keys every hour.
    static let defaultRenegotiationInterval: TimeInterval = 3600
    /// How long the previous key still decrypts after a renegotiation.
    static let transitionWindow: TimeInterval = 60
    static let dynamicTlsCryptLabel = "EXPORTER-OpenVPN-dynamic-tls-crypt"

    private var handWindow: TimeInterval {
        profile.handWindow.map(TimeInterval.init) ?? Self.defaultHandWindow
    }

    public init(profile: OVPNProfile) {
        self.profile = profile
        self.negotiatedCipher = profile.cipher
        self.negotiatedDigest = profile.effectiveDigest
    }

    // MARK: - Lifecycle

    public func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardown()
            self.wantsConnection = true
            self.reconnectGeneration &+= 1
            self.reconnectAttempt = 0
            self.remoteOrder = self.profile.remoteRandom ? self.profile.remotes.shuffled() : self.profile.remotes
            self.remoteIndex = 0
            self.addressIndex = 0
            self.currentAddresses = []
            self.doConnect()
        }
    }

    /// Disconnects, first telling the server (control-channel `EXIT` when
    /// negotiated, otherwise an OCC exit on UDP) so it can release the
    /// session immediately. `completion` runs on the connection queue once
    /// the transport is closed.
    public func disconnect(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else {
                completion?()
                return
            }
            self.wantsConnection = false
            self.reconnectGeneration &+= 1
            let notified = self.state == .ready && self.sendExitNotification()
            let finish = { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                self.teardown()
                self.state = .disconnected
                completion?()
            }
            if notified {
                // Let the notification (and its TCP framing) reach the wire.
                self.queue.asyncAfter(deadline: .now() + 0.25, execute: finish)
            } else {
                finish()
            }
        }
    }

    /// Rebuilds the transport immediately after the host network changes.
    ///
    /// A raw UDP/TCP socket can survive sleep or an interface switch at the
    /// kernel level while its route, Wi-Fi association, or NAT mapping no
    /// longer does. Reusing that socket leaves the packet tunnel looking
    /// alive but unable to exchange packets. This method invalidates any
    /// older delayed reconnect and opens a fresh socket on the given
    /// physical interface.
    public func reconnectForNetworkChange(bindInterfaceName: String?) {
        self.bindInterfaceName = bindInterfaceName
        queue.async { [weak self] in
            guard let self, self.wantsConnection else { return }
            self.reconnectGeneration &+= 1
            self.reconnectAttempt = 0
            self.addressIndex = 0
            self.currentAddresses = []
            self.teardown()
            self.state = .reconnecting
            self.log("network changed: reconnecting immediately")
            self.doConnect()
        }
    }

    private func doConnect() {
        if let issue = profile.fatalIssues.first {
            fail(.invalidProfile(issue.message))
            return
        }
        guard !remoteOrder.isEmpty else {
            fail(.invalidProfile("no remote configured"))
            return
        }
        let remote = remoteOrder[remoteIndex % remoteOrder.count]
        lock.withLock { _currentRemote = remote }
        activeTransport = profile.transport(for: remote)
        negotiationDeadline = Date().timeIntervalSince1970 + handWindow
        authPending = false
        state = .connecting
        startTick()

        if !currentAddresses.isEmpty {
            connectToCurrentAddress(remote)
            return
        }

        // getaddrinfo blocks; resolve off the connection queue.
        let generation = transportGeneration
        let stream = activeTransport == .tcp
        log("resolving \(remote.host)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let addresses = Self.resolve(remote, stream: stream)
            self?.queue.async { [weak self] in
                guard let self, self.wantsConnection, self.transportGeneration == generation else { return }
                let key = "\(remote.host):\(remote.port)"
                if addresses.isEmpty {
                    guard let cached = self.resolvedCache[key] else {
                        self.fail(.resolveFailed(remote.host))
                        return
                    }
                    self.log("cannot resolve \(remote.host): using the last known address")
                    self.currentAddresses = cached
                } else {
                    self.resolvedCache[key] = addresses
                    self.currentAddresses = addresses
                }
                self.addressIndex = min(self.addressIndex, self.currentAddresses.count - 1)
                self.connectToCurrentAddress(remote)
            }
        }
    }

    private func connectToCurrentAddress(_ remote: OVPNProfile.Remote) {
        let address = currentAddresses[addressIndex % currentAddresses.count]
        log("connecting to \(remote.host) [\(address)]:\(remote.port) (\(activeTransport.rawValue))")
        if openTransport(address) {
            startSession()
        }
    }

    /// Creates and connects the transport socket. Returns true when the
    /// transport is ready (UDP connects synchronously); for TCP the session
    /// starts from the connect-completion handler instead.
    private func openTransport(_ address: ResolvedRemote) -> Bool {
        let isTCP = activeTransport == .tcp
        let family: Int32
        switch address {
        case .ipv4: family = AF_INET
        case .ipv6: family = AF_INET6
        }

        let fd = Darwin.socket(family, isTCP ? SOCK_STREAM : SOCK_DGRAM, isTCP ? IPPROTO_TCP : IPPROTO_UDP)
        guard fd >= 0 else {
            fail(.socketError(String(cString: strerror(errno))))
            return false
        }
        socketFD = fd
        // Non-blocking: reads drain until EAGAIN and re-arm via the
        // DispatchSourceRead; the TCP connect completes via a write source.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        if isTCP {
            var nodelay: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        }

        // Bind the transport to the physical interface so it does not route
        // through the tunnel once the tunnel becomes the default route.
        if let iface = bindInterfaceName {
            let ifindex = if_nametoindex(iface)
            if ifindex != 0 {
                var index = ifindex
                let proto = (family == AF_INET6) ? IPPROTO_IPV6 : IPPROTO_IP
                let optname = (family == AF_INET6) ? IPV6_BOUND_IF : IP_BOUND_IF
                setsockopt(fd, proto, optname, &index, socklen_t(MemoryLayout<UInt32>.size))
            }
        }

        // The read source owns the descriptor: it is closed from the cancel
        // handler, never while the source may still reference it (closing
        // first lets a new socket reuse the number under a live source).
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in
            self?.drainTransport()
        }
        read.setCancelHandler {
            Darwin.close(fd)
        }
        read.resume()
        readSource = read

        let rc: Int32
        switch address {
        case .ipv4(var addr):
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case .ipv6(var addr):
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }

        if !isTCP {
            guard rc == 0 else {
                fail(.socketError(String(cString: strerror(errno))))
                return false
            }
            return true
        }

        if rc == 0 {
            tcpEstablished = true
            return true
        }
        guard errno == EINPROGRESS else {
            fail(.socketError(String(cString: strerror(errno))))
            return false
        }
        let generation = transportGeneration
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            source?.cancel()
            guard let self, self.transportGeneration == generation else { return }
            self.tcpWriteSource = nil
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else {
                self.fail(.socketError("tcp connect: \(String(cString: strerror(error)))"))
                return
            }
            self.tcpEstablished = true
            self.startSession()
        }
        source.resume()
        tcpWriteSource = source
        return false
    }

    /// Brings up the TLS control channel once the transport is connected.
    private func startSession() {
        // Every transport reconnect is a new TLS/OpenVPN session. In
        // particular, the client key material must be sent again; retaining
        // it would make a post-sleep reconnect wait forever for a
        // PUSH_REPLY that can never arrive.
        pushedOptions = nil
        pendingPushOptions = []
        peerID = 0
        peerDataV1 = false
        dataChannelVerified = false
        nextKeyID = 1
        lastReceiveTime = Date().timeIntervalSince1970
        lastDataSendTime = 0
        state = .connecting

        var tlsAuth: TLSAuth?
        var tlsCrypt: TlsCrypt?
        var originalKey: Data?
        if let pem = profile.tlsAuthPEM {
            guard let staticKey = try? OpenVPNStaticKey.parse(pem: pem) else {
                fail(.invalidProfile("the <tls-auth> key is not a valid OpenVPN static key"))
                return
            }
            // tls-auth: the HMAC digest is the profile's `auth` setting
            // (SHA1 by default); the key slots follow key-direction.
            let keys = staticKey.tlsAuthKeys(direction: profile.keyDirection)
            tlsAuth = TLSAuth(digest: profile.effectiveDigest, sendKey: keys.send, verifyKey: keys.verify)
            originalKey = staticKey.rawKeyMaterial
        } else if let pem = profile.tlsCryptPEM {
            guard let staticKey = try? OpenVPNStaticKey.parse(pem: pem) else {
                fail(.invalidProfile("the <tls-crypt> key is not a valid OpenVPN static key"))
                return
            }
            // tls-crypt (v1): the client encrypts with keys[1] and decrypts
            // with keys[0] (KEY_DIRECTION_INVERSE), like tls-crypt-v2.
            tlsCrypt = TlsCrypt(clientKey: .v1(staticKey: staticKey))
            originalKey = staticKey.rawKeyMaterial
        } else if let tlsCryptV2 = profile.tlsCryptV2PEM {
            guard let decoded = PEMKeyExtractor.extractKey(from: tlsCryptV2),
                  let clientKey = TlsCrypt.ClientKey.parse(decoded: decoded) else {
                fail(.invalidProfile("the <tls-crypt-v2> key is not a valid client key"))
                return
            }
            // tls-crypt-v2: wrap all control packets with the client key.
            tlsCrypt = TlsCrypt(clientKey: clientKey)
            originalKey = clientKey.kc
        }
        let wrapper = ControlWrapper(tlsAuth: tlsAuth, tlsCrypt: tlsCrypt, originalKeyMaterial: originalKey)
        self.wrapper = wrapper
        localSessionID = KeyMethod2.randomBytes(8)

        guard let key = makeKeyState(keyID: 0, remoteSessionID: nil, softReset: false) else { return }
        primary = key
        key.channel.sendReset()
    }

    /// Creates a key state: a fresh TLS session and reliable channel on
    /// `keyID`, plus this client's key_method_2 material.
    private func makeKeyState(keyID: UInt8, remoteSessionID: Data?, softReset: Bool) -> KeyState? {
        guard let ca = profile.caPEM, let wrapper else { return nil }
        do {
            let tls = try TLSEngine(
                caPEM: ca,
                certPEM: profile.certPEM,
                keyPEM: profile.keyPEM,
                extraCertsPEM: profile.extraCertsPEM,
                keyPassphrase: profile.keyPassphrase,
                minimumVersion: profile.tlsVersionMin,
                cipherList: profile.tlsCipher,
                cipherSuites: profile.tlsCiphersuites
            )
            let channel = ControlChannel(
                keyID: keyID,
                localSessionID: localSessionID,
                remoteSessionID: remoteSessionID,
                tls: tls,
                wrapper: wrapper,
                softReset: softReset,
                sendWire: { [weak self] packet in
                    self?.sendWire(packet)
                }
            )
            channel.debugLog = { [weak self] text in
                guard let self, self.verboseLogging else { return }
                self.log(text)
            }

            // A pushed auth-token replaces the password on later sessions
            // and renegotiations.
            usingAuthToken = authToken != nil
            var protocolBits = PeerInfo.protocolBits
            if !preferTLSKeyExport {
                protocolBits &= ~(1 << 3)   // IV_PROTO_TLS_KEY_EXPORT
            }
            let material = KeyMethod2.makeClientMaterial(
                options: OptionsString.build(profile: profile, transport: activeTransport),
                username: usingAuthToken ? (authTokenUser ?? profile.authUserPass?.username) : profile.authUserPass?.username,
                password: usingAuthToken ? authToken : profile.authUserPass?.password,
                peerInfo: PeerInfo.build(ciphers: profile.announcedCiphers, protocolBits: protocolBits)
            )
            return KeyState(keyID: keyID, channel: channel, clientMaterial: material,
                            started: Date().timeIntervalSince1970)
        } catch let error as TLSEngineError {
            fail(.tlsSetupFailed(error.description))
        } catch {
            fail(.tlsSetupFailed("\(error)"))
        }
        return nil
    }

    private func teardown() {
        transportGeneration &+= 1
        tickSource?.cancel()
        tickSource = nil
        tcpWriteSource?.cancel()
        tcpWriteSource = nil
        // Cancelling the read source closes the descriptor.
        readSource?.cancel()
        readSource = nil
        socketFD = -1
        tcpEstablished = false
        tcpFramer = TCPPacketFramer()
        tcpOutbound = Data()
        primary = nil
        pending = nil
        lameDuck = nil
        wrapper = nil
    }

    // MARK: - Transport

    /// Sends one OpenVPN packet. UDP: a datagram. TCP: length-prefixed
    /// (uint16 big-endian) per the OpenVPN TCP wire format.
    private func sendWire(_ packet: Data) {
        packetObserver?(true, packet)
        guard socketFD >= 0 else { return }
        if activeTransport == .tcp {
            guard tcpEstablished else { return }
            tcpOutbound.append(TCPPacketFramer.frame(packet))
            flushTCPOutbound()
        } else {
            packet.withUnsafeBytes { ptr in
                _ = Darwin.send(socketFD, ptr.baseAddress, packet.count, 0)
            }
        }
    }

    /// Writes as much of the pending TCP output as the socket accepts and
    /// arms a writability source for the rest.
    private func flushTCPOutbound() {
        guard socketFD >= 0 else { return }
        while !tcpOutbound.isEmpty {
            let sent = tcpOutbound.withUnsafeBytes { ptr -> Int in
                Darwin.send(socketFD, ptr.baseAddress, ptr.count, 0)
            }
            if sent > 0 {
                tcpOutbound.removeFirst(sent)
            } else if sent < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    armTCPWriteSource()
                } else {
                    fail(.socketError("tcp send: \(String(cString: strerror(err)))"))
                }
                return
            }
        }
    }

    private func armTCPWriteSource() {
        guard tcpWriteSource == nil, socketFD >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: socketFD, queue: queue)
        let generation = transportGeneration
        source.setEventHandler { [weak self] in
            guard let self, self.transportGeneration == generation else { return }
            self.flushTCPOutbound()
            if self.tcpOutbound.isEmpty {
                self.tcpWriteSource?.cancel()
                self.tcpWriteSource = nil
            }
        }
        source.resume()
        tcpWriteSource = source
    }

    private func startTick() {
        guard tickSource == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.25, repeating: 0.25)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        tickSource = source
    }

    /// Reads everything available. Any packet may tear the transport down
    /// (failure, reconnect); the loop stops as soon as the transport it was
    /// started for is gone.
    private func drainTransport() {
        let generation = transportGeneration
        let fd = socketFD
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while transportGeneration == generation {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                if activeTransport == .tcp {
                    let packets: [Data]
                    do {
                        packets = try tcpFramer.feed(Data(buffer[0..<n]))
                    } catch {
                        fail(.socketError("tcp framing: \(error)"))
                        return
                    }
                    for packet in packets {
                        guard transportGeneration == generation else { return }
                        receivePacket(packet)
                    }
                } else {
                    receivePacket(Data(buffer[0..<n]))
                }
                continue
            }
            if n == 0, activeTransport == .tcp {
                fail(.socketError("connection closed by server"))
                return
            }
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                return
            }
            if activeTransport == .tcp {
                fail(.socketError("tcp recv: \(String(cString: strerror(err)))"))
            } else if err == ECONNREFUSED, state != .ready {
                // ICMP port unreachable on the connected UDP socket: the
                // server is not listening here; try the next address.
                fail(.socketError("connection refused"))
            }
            return
        }
    }

    private func receivePacket(_ packet: Data) {
        packetObserver?(false, packet)
        processIncoming(packet)
    }

    // MARK: - State machine

    private func processIncoming(_ packet: Data) {
        guard let first = packet.first, let opcode = PacketHeader.opcode(of: first) else {
            return  // unknown opcode: drop
        }
        if opcode.isData {
            handleDataPacket(packet)
            return
        }

        let keyID = first & 0x07
        let key: KeyState
        if let pending, pending.keyID == keyID {
            key = pending
        } else if let primary, primary.keyID == keyID {
            guard pending == nil else { return }   // superseded control channel
            key = primary
        } else if let lameDuck, lameDuck.keyID == keyID {
            return   // retired key: data only
        } else if opcode == .controlSoftResetV1, keyID != 0 {
            // The server starts a renegotiation on a new key-id. Only an
            // authentic packet of this session may do that.
            guard state == .ready, pending == nil, let primary, primary.channel.isAuthentic(packet) else { return }
            startRenegotiation(keyID: keyID, serverPacket: packet)
            return
        } else {
            return
        }
        receiveControl(packet, on: key)
    }

    /// Feeds a control packet into a key state's reliable channel and acts
    /// on what comes out of TLS.
    private func receiveControl(_ packet: Data, on key: KeyState) {
        let channel = key.channel
        do {
            let messages = try channel.receive(packet)
            lastReceiveTime = Date().timeIntervalSince1970
            for message in messages {
                handleControlMessage(message, on: key)
                guard isLive(key) else { return }   // torn down or replaced
            }
            // TLS handshake may have completed as a side effect. Before
            // trusting the channel, the peer certificate must pass the
            // profile's remote-cert-tls / verify-x509-name checks.
            if !key.sentKeyMaterial, channel.tls.isHandshaken {
                try channel.tls.verifyPeer(
                    requireServerEKU: profile.remoteCertTLS == .server,
                    name: requestedNameMatch()
                )
                if key.keyID == 0 {
                    log("peer verified: \(channel.tls.peerSubject ?? "<no subject>")")
                }
                sendKeyMaterial(on: key)
            }
        } catch let error as TLSEngineError {
            fail(.tlsSetupFailed(error.description))
        } catch ControlChannelError.malformedPacket {
            // Unauthenticated garbage (e.g. tls-auth HMAC failure): drop
            // the datagram, keep the session, as OpenVPN does.
            if verboseLogging {
                log("control: dropped malformed packet")
            }
        } catch {
            fail(.protocolError("control channel error: \(error)"))
        }
    }

    private func isLive(_ key: KeyState) -> Bool {
        key === primary || key === pending
    }

    /// Maps the profile's `verify-x509-name` onto the engine's name match.
    private func requestedNameMatch() -> TLSEngine.X509NameMatch? {
        switch profile.x509NameCheck {
        case .verifyName(let name, .name): return .commonName(name)
        case .verifyName(let name, .namePrefix): return .commonNamePrefix(name)
        case .verifyName(let name, .subject): return .subject(name)
        case nil: return nil
        }
    }

    private func handleControlMessage(_ message: Data, on key: KeyState) {
        if message == Self.pingString {
            return
        }
        if key.sentKeyMaterial, key.serverMaterial == nil,
           let server = KeyMethod2.parse(server: message) {
            if verboseLogging {
                log("server options: \(server.options)")
            }
            key.serverMaterial = server
            if key === pending {
                completeRenegotiation(key)
            } else {
                state = .derivingKeys
                deriveMaterials(for: key)
            }
            return
        }

        let text = PushParser.text(of: message)
        if verboseLogging {
            log("control message: \(text.prefix(600))")
        }
        if text.hasPrefix("PUSH_REPLY") {
            handlePushReply(text)
            return
        }

        switch ServerControlMessage.parse(text) {
        case .authFailed(let reason, let temporary, let backoff):
            if usingAuthToken, !temporary {
                // The pushed auth-token expired (or the server restarted):
                // retry once with the original credentials, as OpenVPN does.
                log("auth-token rejected: retrying with the saved credentials")
                authToken = nil
                authTokenUser = nil
                reconnect(advance: false, delay: 0)
            } else if temporary {
                fail(.authFailedTemporary(reason, backoff: backoff))
            } else {
                fail(.authFailed(reason))
            }
        case .authPending(let timeout, let keywords):
            // Out-of-band authentication (2FA, web login) is in progress:
            // keep waiting instead of giving up after the usual attempts.
            authPending = true
            let maxWindow = max(handWindow, renegotiationInterval / 2)
            let window = min(maxWindow, TimeInterval(timeout ?? Int(handWindow)))
            negotiationDeadline = Date().timeIntervalSince1970 + window
            log("authentication pending (\(keywords.joined(separator: ", "))): waiting up to \(Int(window))s")
        case .restart(let reason, let advance):
            log("server requested restart\(reason.isEmpty ? "" : ": \(reason)")")
            failOrReconnect(.serverRestart(reason), advance: advance)
        case .halt(let reason):
            fail(.serverHalt(reason))
        case .exit:
            log("server is shutting down")
            failOrReconnect(.serverExit, advance: true)
        case .info(let info):
            log("server info: \(info)")
        case .other(let other):
            if !other.isEmpty {
                log("ignoring control message: \(other.prefix(80))")
            }
        }
    }

    private func sendKeyMaterial(on key: KeyState) {
        key.sentKeyMaterial = true
        do {
            try key.channel.sendMessage(KeyMethod2.encode(client: key.clientMaterial))
            if key === primary, state != .ready {
                state = .authenticating
            }
        } catch {
            fail(.protocolError("key material send failed: \(error)"))
        }
    }

    /// Derives the key material with both methods. The actual choice
    /// (EKM vs classic PRF) happens when the PUSH_REPLY arrives —
    /// OpenVPN likewise imports the pushed options before generating
    /// the data channel keys.
    private func computeMaterials(for key: KeyState) -> Bool {
        guard let server = key.serverMaterial else { return false }
        if preferTLSKeyExport {
            key.ekmMaterial = try? KeyExpansion.deriveExporter(tls: key.channel.tls)
            if key.ekmMaterial == nil {
                log("exporter unavailable, EKM disabled")
            }
        }
        key.prfMaterial = KeyExpansion.derivePRF(
            client: key.clientMaterial, server: server,
            clientSessionID: localSessionID,
            serverSessionID: key.channel.remoteSessionID ?? Data(count: 8)
        )
        return key.prfMaterial != nil
    }

    private func deriveMaterials(for key: KeyState) {
        guard computeMaterials(for: key) else {
            fail(.keyDerivationFailed)
            return
        }
        state = .waitPush
        negotiationDeadline = Date().timeIntervalSince1970 + handWindow
        pushRequestAttempts = 0
        key.channel.sendAckIfNeeded(now: Date().timeIntervalSince1970)
        requestPush()
    }

    /// Builds the data-channel keys of a key state from the pushed options
    /// (EKM vs PRF, cipher, epoch format).
    private func makeDataCrypto(for key: KeyState, pushed: PushedOptions) -> DataChannelCrypto? {
        let material: Data
        if pushed.useTLSKeyExport {
            // The server demands EKM; falling back would silently produce
            // a key mismatch.
            guard let ekm = key.ekmMaterial else { return nil }
            material = ekm
        } else {
            guard let prf = key.prfMaterial else { return nil }
            material = prf
        }
        guard let keySet = KeyExpansion.keySet(material: material, cipher: negotiatedCipher, digest: negotiatedDigest) else {
            return nil
        }
        var epochKeys: DataChannelEpochKeySet?
        if pushed.aeadEpoch {
            guard let keys = KeyExpansion.epochKeySet(material: material, cipher: negotiatedCipher) else { return nil }
            epochKeys = keys
        }
        return DataChannelCrypto(
            keys: keySet,
            epochKeys: epochKeys,
            replay: profile.replayWindow.map { ReplayWindow(windowSize: $0) } ?? ReplayWindow()
        )
    }

    private func requestPush() {
        guard let channel = primary?.channel else { return }
        do {
            // Control-channel string messages are sent with their trailing
            // NUL (OpenVPN's tls_send_payload(strlen+1)); the server's
            // command parser requires it.
            try channel.sendMessage(Data("PUSH_REQUEST".utf8) + Data([0]))
            lastPushRequestAt = Date().timeIntervalSince1970
            pushRequestAttempts += 1
        } catch {
            fail(.protocolError("push request failed: \(error)"))
        }
    }

    private func handlePushReply(_ text: String) {
        guard state == .waitPush, let key = primary else {
            // Mid-session updates (PUSH_UPDATE) are not supported; a
            // duplicate PUSH_REPLY for an already established session is
            // harmless.
            return
        }
        pendingPushOptions += PushParser.splitOptions(text)
        let pushed = PushParser.parse(options: pendingPushOptions)
        if pushed.continuation == 2 {
            log("PUSH_REPLY continues in the next message")
            return
        }
        pendingPushOptions = []

        if let cipher = pushed.unsupportedCipher {
            fail(.unsupportedCipher(cipher))
            return
        }

        if let peerID = pushed.peerID {
            self.peerID = peerID
        }
        if let cipher = pushed.cipher {
            negotiatedCipher = cipher
            log("negotiated cipher: \(cipher.rawValue)")
        }
        if let digest = pushed.digest {
            negotiatedDigest = digest
            log("negotiated auth: \(digest.rawValue)")
        }
        pingInterval = TimeInterval(pushed.pingSeconds ?? profile.pingSeconds ?? 10)
        pingRestart = TimeInterval(pushed.pingRestartSeconds ?? profile.pingRestartSeconds ?? 60)
        if let token = pushed.authToken {
            authToken = token
            authTokenUser = pushed.authTokenUser ?? authTokenUser
            log("received auth-token for reconnects")
        }

        // The push decides the key derivation method and the cipher —
        // exactly OpenVPN's "import pushed options, then generate keys".
        guard let crypto = makeDataCrypto(for: key, pushed: pushed) else {
            fail(.keyDerivationFailed)
            return
        }
        log("key derivation: \(pushed.useTLSKeyExport ? "tls-ekm" : "OpenVPN PRF")\(pushed.aeadEpoch ? ", aead-epoch data format" : "")")
        key.crypto = crypto
        key.established = Date().timeIntervalSince1970
        pushedOptions = pushed

        // Dynamic tls-crypt: renegotiations are wrapped with a key exported
        // from this first TLS session.
        if pushed.protocolFlags.contains("dyn-tls-crypt"), let wrapper {
            if let exported = key.channel.tls.exportKeyMaterial(label: Self.dynamicTlsCryptLabel, length: TlsCrypt.keyMaterialLength) {
                wrapper.enableDynamicTlsCrypt(exportedKey: exported)
            } else {
                log("dynamic tls-crypt key export failed")
            }
        }

        peerDataV1 = false
        reconnectAttempt = 0
        authPending = false
        negotiationDeadline = .infinity

        state = .ready
        log("connection ready (peer-id \(peerID), cipher \(negotiatedCipher.rawValue))")
    }

    // MARK: - Renegotiation

    /// The renegotiation interval: pushed `reneg-sec`, else the profile's,
    /// else OpenVPN's default of one hour (0 disables).
    private var renegotiationInterval: TimeInterval {
        TimeInterval(pushedOptions?.renegSeconds ?? profile.renegSeconds ?? Int(Self.defaultRenegotiationInterval))
    }

    /// Starts a soft reset on a new key-id. Data keeps flowing on the
    /// current key until the new one is negotiated.
    private func startRenegotiation(keyID requestedKeyID: UInt8? = nil, serverPacket: Data? = nil) {
        guard state == .ready, pending == nil, let primary,
              let remoteSessionID = primary.channel.remoteSessionID else { return }
        let keyID = requestedKeyID ?? nextKeyID
        nextKeyID = keyID >= 7 ? 1 : keyID + 1
        guard let key = makeKeyState(keyID: keyID, remoteSessionID: remoteSessionID, softReset: true) else { return }
        pending = key
        log("renegotiating keys on key-id \(keyID) (\(serverPacket == nil ? "client" : "server") initiated)")
        key.channel.sendReset()
        if let serverPacket {
            receiveControl(serverPacket, on: key)
        }
    }

    /// The server sent its key material for the pending key: switch to the
    /// new data-channel keys and keep the old ones for in-flight packets.
    private func completeRenegotiation(_ key: KeyState) {
        guard computeMaterials(for: key), let pushed = pushedOptions,
              let crypto = makeDataCrypto(for: key, pushed: pushed) else {
            fail(.keyDerivationFailed)
            return
        }
        key.crypto = crypto
        key.established = Date().timeIntervalSince1970
        lameDuck = primary
        lameDuckExpiry = Date().timeIntervalSince1970 + Self.transitionWindow
        primary = key
        pending = nil
        log("renegotiation complete: using key-id \(key.keyID)")
    }

    /// Tells the server this client is leaving. Returns true when a
    /// notification was sent.
    private func sendExitNotification() -> Bool {
        // The control-channel EXIT needs the server's current key; while a
        // renegotiation is pending the old channel is no longer accepted.
        if pushedOptions?.supportsControlChannelExit == true, pending == nil, let channel = primary?.channel {
            do {
                try channel.sendMessage(Data("EXIT".utf8) + Data([0]))
                log("sent EXIT to the server")
                return true
            } catch {
                return false
            }
        }
        guard activeTransport == .udp, primary?.crypto != nil else { return false }
        // OCC exit (explicit-exit-notify) for servers without cc-exit.
        for _ in 0..<2 {
            sendIPPacketLocked(Self.occMagic + Data([Self.occExit]))
        }
        log("sent OCC exit to the server")
        return true
    }

    // MARK: - Data channel

    /// Sends an IP packet through the tunnel. Safe to call from any queue;
    /// the work is serialized on the connection queue.
    public func sendIPPacket(_ payload: Data) {
        queue.async { [weak self] in
            self?.sendIPPacketLocked(payload)
        }
    }

    /// Sends a batch of IP packets with a single queue hop.
    public func sendIPPackets(_ payloads: [Data]) {
        queue.async { [weak self] in
            guard let self else { return }
            for payload in payloads {
                self.sendIPPacketLocked(payload)
            }
        }
    }

    private func sendIPPacketLocked(_ payload: Data) {
        guard state == .ready, let key = primary, var crypto = key.crypto else { return }
        do {
            let packet = try crypto.encryptNext(
                plaintext: payload,
                peerID: peerID,
                keyID: key.keyID,
                useV1Header: peerDataV1
            )
            key.crypto = crypto
            lastDataSendTime = Date().timeIntervalSince1970
            sendWire(packet)
        } catch DataChannelError.packetIDExhausted {
            key.crypto = crypto
            // Never reuse nonces: drop until the renegotiation completes.
            startRenegotiation()
        } catch {
            log("data encrypt error: \(error)")
        }
    }

    private func handleDataPacket(_ packet: Data) {
        let header = packet[packet.startIndex]
        let keyID = header & 0x07
        let key: KeyState
        if let primary, primary.keyID == keyID {
            key = primary
        } else if let lameDuck, lameDuck.keyID == keyID {
            key = lameDuck
        } else {
            return
        }
        guard var crypto = key.crypto else { return }
        let (opcode, _) = PacketHeader.decode(header)
        do {
            let plaintext = try crypto.decrypt(packet, keyID: keyID)
            key.crypto = crypto
            // Only authenticated packets count as liveness or format hints.
            lastReceiveTime = Date().timeIntervalSince1970
            if opcode == .dataV1 {
                peerDataV1 = true
            }
            if !dataChannelVerified {
                dataChannelVerified = true
                log("data channel verified: first packet from the server decrypted")
            }
            if plaintext == Self.pingString {
                return
            }
            if plaintext.starts(with: Self.occMagic) {
                handleOCCMessage(plaintext.dropFirst(Self.occMagic.count))
                return
            }
            delegate?.connection(self, didReceiveIPPacket: plaintext)
        } catch {
            // Replayed or malformed packets are dropped silently; the
            // replay filter is not advanced for them.
            if verboseLogging {
                log("data: dropped packet (\(error))")
            }
        }
    }

    private func handleOCCMessage(_ body: Data) {
        guard let opcode = body.first else { return }
        if opcode == Self.occExit {
            log("server sent OCC exit")
            failOrReconnect(.serverExit, advance: true)
        }
    }

    // MARK: - Timers

    private func tick() {
        let now = Date().timeIntervalSince1970

        if state != .ready, now > negotiationDeadline {
            fail(state == .waitPush ? .pushTimeout : .handshakeTimeout)
            return
        }
        guard let primary else { return }

        // Only the newest key state has a live control channel: an OpenVPN
        // server rejects control packets (even ACKs) on any other key-id,
        // fatally on TCP.
        let active = pending ?? primary
        if active.channel.handshakeTimedOut(now: now, window: handWindow) {
            fail(.handshakeTimeout)
            return
        }
        _ = active.channel.retransmitDue(now: now)
        active.channel.sendAckIfNeeded(now: now)
        if lameDuck != nil, now > lameDuckExpiry {
            lameDuck = nil
        }
        if let pending, now - pending.started > handWindow {
            // OpenVPN: "TLS key negotiation failed to occur within 60 seconds".
            log("renegotiation of key-id \(pending.keyID) did not complete")
            fail(.handshakeTimeout)
            return
        }

        if state == .waitPush, pendingPushOptions.isEmpty {
            // Re-send PUSH_REQUEST every second (every five while the
            // server reports pending authentication) until the deadline.
            let interval: TimeInterval = (authPending || pushRequestAttempts >= Self.maxPushRequestAttempts) ? 5 : 1
            if now - lastPushRequestAt >= interval {
                if verboseLogging {
                    log("re-sending PUSH_REQUEST (attempt \(pushRequestAttempts + 1))")
                }
                requestPush()
            }
        }
        if state == .ready {
            // Keepalive: send the OpenVPN ping string when no data went out
            // for a ping interval.
            if now - lastDataSendTime >= pingInterval {
                sendIPPacketLocked(Self.pingString)
            }
            if now - lastReceiveTime > pingRestart {
                log("ping restart: no packets from the server for \(Int(pingRestart))s")
                reconnect(advance: true)
                return
            }
            if pending == nil, let established = primary.established {
                let interval = renegotiationInterval
                if interval > 0, now - established >= interval {
                    startRenegotiation()
                } else if primary.crypto?.needsRenegotiation == true {
                    log("data-channel key usage limit reached")
                    startRenegotiation()
                }
            }
        }
    }

    /// Tears the transport down and schedules a new connection attempt.
    ///
    /// - Parameter advance: move on to the next address/remote first
    ///   (connection failures), or retry the same one (session refresh).
    /// - Parameter delay: explicit delay; otherwise a short delay while
    ///   untried remotes remain, then exponential backoff (max 30s).
    private func reconnect(advance: Bool, delay: TimeInterval? = nil) {
        teardown()
        guard wantsConnection else {
            state = .disconnected
            return
        }
        var wrapped = false
        if advance {
            wrapped = advanceTarget()
        }
        reconnectAttempt += 1
        let backoff = min(30.0, pow(2.0, Double(min(reconnectAttempt, 6) - 1)))
        let wait = delay ?? ((advance && !wrapped) ? 1.0 : backoff)
        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        state = .reconnecting
        log("reconnecting in \(String(format: "%.0f", wait))s (attempt \(reconnectAttempt))")
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self,
                  self.wantsConnection,
                  self.reconnectGeneration == generation else { return }
            self.doConnect()
        }
    }

    /// Moves to the next resolved address, then to the next remote.
    /// Returns true when every remote has been tried (a full cycle).
    private func advanceTarget() -> Bool {
        addressIndex += 1
        if addressIndex < currentAddresses.count {
            return false
        }
        addressIndex = 0
        currentAddresses = []
        remoteIndex += 1
        if remoteIndex >= remoteOrder.count {
            remoteIndex = 0
            return true
        }
        return false
    }

    private func failOrReconnect(_ error: ConnectionError, advance: Bool) {
        if error.isPermanent || !wantsConnection {
            fail(error)
        } else {
            log("\(error)")
            reconnect(advance: advance, delay: advance ? nil : 1)
        }
    }

    private func fail(_ error: ConnectionError) {
        log("error: \(error)")
        teardown()
        if error.isPermanent || !wantsConnection {
            wantsConnection = false
            state = .failed(error.description)
            return
        }
        switch error {
        case .authFailedTemporary(_, let backoff):
            reconnect(advance: false, delay: TimeInterval(backoff ?? 10))
        default:
            // Connection-level failures: try the next address/remote.
            reconnect(advance: true)
        }
    }

    private func log(_ message: String) {
        delegate?.connection(self, log: message)
    }

    // MARK: - Helpers

    /// One TLS session on one key-id and the data-channel keys it produced.
    private final class KeyState {
        let keyID: UInt8
        let channel: ControlChannel
        let clientMaterial: KeyMethod2.ClientMaterial
        var serverMaterial: KeyMethod2.ServerMaterial?
        var sentKeyMaterial = false
        /// Key material from both derivations; the PUSH_REPLY decides which
        /// one the server uses (`key-derivation tls-ekm` vs classic PRF).
        var ekmMaterial: Data?
        var prfMaterial: Data?
        var crypto: DataChannelCrypto?
        let started: TimeInterval
        var established: TimeInterval?

        init(keyID: UInt8, channel: ControlChannel, clientMaterial: KeyMethod2.ClientMaterial, started: TimeInterval) {
            self.keyID = keyID
            self.channel = channel
            self.clientMaterial = clientMaterial
            self.started = started
        }
    }

    enum ResolvedRemote: CustomStringConvertible {
        case ipv4(sockaddr_in)
        case ipv6(sockaddr_in6)

        var description: String {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            switch self {
            case .ipv4(var addr):
                inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(buffer.count))
            case .ipv6(var addr):
                inet_ntop(AF_INET6, &addr.sin6_addr, &buffer, socklen_t(buffer.count))
            }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// Resolves every address of a remote: IPv4 first, then IPv6, unless
    /// the remote's protocol restricts the family (`udp4`, `tcp6`, ...).
    static func resolve(_ remote: OVPNProfile.Remote, stream: Bool) -> [ResolvedRemote] {
        var hints = addrinfo()
        switch remote.family {
        case .ipv4: hints.ai_family = AF_INET
        case .ipv6: hints.ai_family = AF_INET6
        case nil: hints.ai_family = AF_UNSPEC
        }
        hints.ai_socktype = stream ? SOCK_STREAM : SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(remote.host, "\(remote.port)", &hints, &result) == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var v4: [ResolvedRemote] = []
        var v6: [ResolvedRemote] = []
        while let current = cursor {
            if current.pointee.ai_family == AF_INET, let addr = current.pointee.ai_addr {
                v4.append(.ipv4(addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }))
            } else if current.pointee.ai_family == AF_INET6, let addr = current.pointee.ai_addr {
                v6.append(.ipv6(addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }))
            }
            cursor = current.pointee.ai_next
        }
        return v4 + v6
    }
}
