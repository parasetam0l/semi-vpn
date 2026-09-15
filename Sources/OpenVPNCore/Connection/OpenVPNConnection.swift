import Foundation
import Darwin

public enum ConnectionError: Error, Sendable, Equatable {
    case invalidProfile(String)
    case socketError(String)
    case tlsSetupFailed(String)
    case handshakeTimeout
    case authFailed(String)
    case serverRestart(String)
    case serverHalt
    case protocolError(String)
    case keyDerivationFailed
    case disconnected
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

    /// Connection state. Mutated only on the connection queue, but read
    /// from any thread (CLI, UI) — guarded so the enum read cannot tear.
    public private(set) var state: State {
        get { stateLock.withLock { _state } }
        set {
            stateLock.withLock { _state = newValue }
            delegate?.connection(self, stateChanged: newValue)
        }
    }
    private var _state: State = .idle
    private let stateLock = NSLock()

    /// Optional raw wire-packet observer for diagnostics.
    public var packetObserver: ((Bool, Data) -> Void)?

    public let profile: OVPNProfile
    public weak var delegate: Delegate?

    /// When true, data-channel keys are derived via the RFC 5705 exporter
    /// (requires the server to push `key-derivation tls-ekm`).
    public var preferTLSKeyExport = true

    /// The interface name the tunnel's UDP socket binds to (e.g. "en0").
    /// Required when the tunnel itself becomes the default route: the
    /// transport must not route through itself.
    public var bindInterfaceName: String?

    public private(set) var negotiatedCipher: OVPNProfile.Cipher
    public private(set) var negotiatedDigest: OVPNProfile.Digest
    public private(set) var peerID: UInt32 = 0
    public private(set) var pushedOptions: PushedOptions?

    /// Indicates whether the active connection session negotiated an IPv6 configuration.
    public var hasVPNIPv6: Bool {
        if let pushed = pushedOptions, pushed.ifconfigIPv6Local != nil {
            return true
        }
        return profile.ifconfigIPv6Local != nil
    }

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    /// All connection state is confined to this serial queue; callers of
    /// the public API (packet flow, UI) hop onto it.
    private let queue = DispatchQueue(label: "com.semivpn.OpenVPNConnection", qos: .userInitiated)

    // TCP transport state (profile.transport == .tcp)
    private var tcpEstablished = false
    private var tcpFramer = TCPPacketFramer()   // inbound stream reassembly
    private var tcpOutbound = Data()            // packets awaiting a full socket write
    private var tcpWriteSource: DispatchSourceWrite?

    private var control: ControlChannel?
    private var clientMaterial: KeyMethod2.ClientMaterial?
    private var serverMaterial: KeyMethod2.ServerMaterial?
    /// Key material from both derivations; the PUSH_REPLY decides which
    /// one the server uses (`key-derivation tls-ekm` vs classic PRF), the
    /// same way OpenVPN imports pushed options before generating keys.
    private var prfMaterial: Data?
    private var ekmMaterial: Data?
    private var dataCrypto: DataChannelCrypto?
    private var sendCounter: UInt64 = 0
    /// The peer's data format: servers that announce no DATA_V2 support use
    /// P_DATA_V1; we mirror whatever the peer sends.
    private var peerDataV1 = false
    private var sentKeyMaterial = false
    private var lastReceiveTime: TimeInterval = 0
    private var lastPingSend: TimeInterval = 0
    private var pingInterval: TimeInterval = 10
    private var pingRestart: TimeInterval = 60

    // PUSH_REQUEST retry state (the official client re-sends it every
    // second until PUSH_REPLY; a single request is not enough on some
    // servers).
    private var lastPushRequestAt: TimeInterval = 0
    private var pushRequestAttempts = 0

    // Session lifetime: the server's reneg-sec, plus a proactive refresh
    // before the 32-bit data packet-id space is exhausted.
    private var sessionDeadline: TimeInterval?

    // Reconnect loop with exponential backoff; runs until disconnect().
    private var wantsConnection = false
    private var reconnectAttempt = 0
    /// Invalidates delayed reconnect closures when a newer lifecycle event
    /// has already replaced the transport.
    private var reconnectGeneration: UInt64 = 0

    private var timerActive = true
    private var tickSource: DispatchSourceTimer?

    /// Logs control-message contents when enabled (off in production).
    public var verboseLogging = false

    /// Proactive session refresh below the 32-bit packet-id ceiling so the
    /// GCM nonce space is never approached (epoch format has 2^48 and does
    /// not need this).
    static let dataChannelRenewalThreshold: UInt64 = 4_000_000_000
    static let maxPushRequestAttempts = 10

    public init(profile: OVPNProfile) {
        self.profile = profile
        self.negotiatedCipher = profile.cipher
        self.negotiatedDigest = profile.digest ?? .sha256
    }

    // MARK: - Lifecycle

    public func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsConnection = true
            self.reconnectGeneration &+= 1
            self.reconnectAttempt = 0
            self.doConnect()
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsConnection = false
            self.reconnectGeneration &+= 1
            self.teardown()
            self.state = .disconnected
        }
    }

    /// Rebuilds the transport immediately after the host network resumes.
    ///
    /// A raw UDP/TCP socket can survive sleep at the kernel level while its
    /// route, Wi-Fi association, or NAT mapping no longer does. Reusing that
    /// socket leaves the packet tunnel looking alive but unable to exchange
    /// packets. This method invalidates any older delayed reconnect and opens
    /// a fresh socket on the current physical interface.
    public func reconnectForNetworkChange(bindInterfaceName: String?) {
        queue.async { [weak self] in
            guard let self, self.wantsConnection else { return }
            self.bindInterfaceName = bindInterfaceName
            self.reconnectGeneration &+= 1
            self.reconnectAttempt = 0
            self.teardown()
            self.state = .reconnecting
            self.log("network resumed: reconnecting immediately")
            self.doConnect()
        }
    }

    private func doConnect() {
        guard let remote = profile.primaryRemote else {
            fail(.invalidProfile("no remote configured"))
            return
        }
        guard profile.caPEM != nil else {
            fail(.invalidProfile("no CA certificate"))
            return
        }

        timerActive = true
        log("connecting to \(remote.host):\(remote.port) (\(profile.transport.rawValue))")
        if openTransport(remote) {
            startSession()
        }
    }

    /// Creates and connects the transport socket. Returns true when the
    /// transport is ready (UDP connects synchronously); for TCP the session
    /// starts from the connect-completion handler instead.
    private func openTransport(_ remote: OVPNProfile.Remote) -> Bool {
        let isTCP = profile.transport == .tcp
        guard let resolved = resolveRemote(remote.host, port: remote.port, stream: isTCP) else {
            fail(.socketError("cannot resolve \(remote.host)"))
            return false
        }

        let family: Int32
        switch resolved {
        case .ipv4: family = AF_INET
        case .ipv6: family = AF_INET6
        }

        socketFD = Darwin.socket(family, isTCP ? SOCK_STREAM : SOCK_DGRAM, isTCP ? IPPROTO_TCP : IPPROTO_UDP)
        guard socketFD >= 0 else {
            fail(.socketError(String(cString: strerror(errno))))
            return false
        }
        // Non-blocking: reads drain until EAGAIN and re-arm via the
        // DispatchSourceRead; the TCP connect completes via a write source.
        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        if isTCP {
            var nodelay: Int32 = 1
            setsockopt(socketFD, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        }

        // Bind the transport to the physical interface so it does not route
        // through the tunnel once the tunnel becomes the default route.
        if let iface = bindInterfaceName {
            let ifindex = if_nametoindex(iface)
            if ifindex != 0 {
                var index = ifindex
                let proto = (family == AF_INET6) ? IPPROTO_IPV6 : IPPROTO_IP
                let optname = (family == AF_INET6) ? IPV6_BOUND_IF : IP_BOUND_IF
                setsockopt(socketFD, proto, optname, &index, socklen_t(MemoryLayout<UInt32>.size))
            }
        }

        let rc: Int32
        switch resolved {
        case .ipv4(var addr):
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case .ipv6(var addr):
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
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
        let source = DispatchSource.makeWriteSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            source?.cancel()
            guard let self else { return }
            self.tcpWriteSource = nil
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(self.socketFD, SOL_SOCKET, SO_ERROR, &error, &length)
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
        guard let ca = profile.caPEM else { return }
        // Every transport reconnect is a new TLS/OpenVPN session. In
        // particular, the client key material must be sent again; retaining
        // this flag would make a post-sleep reconnect wait forever for a
        // PUSH_REPLY that can never arrive.
        sentKeyMaterial = false
        serverMaterial = nil
        prfMaterial = nil
        ekmMaterial = nil
        pushedOptions = nil
        sessionDeadline = nil
        peerID = 0
        peerDataV1 = false
        sendCounter = 0
        lastReceiveTime = Date().timeIntervalSince1970
        lastPingSend = 0
        state = .connecting

        do {
            let tls = try TLSEngine(caPEM: ca, certPEM: profile.certPEM, keyPEM: profile.keyPEM)

            var tlsAuth: TLSAuth?
            var tlsCrypt: TlsCrypt?
            if let staticKey = try? profile.tlsAuthPEM.flatMap({ try OpenVPNStaticKey.parse(pem: $0) }) {
                // tls-auth: the HMAC digest is the profile's `auth` setting;
                // a client with key-direction 1 signs with keys[1] and
                // verifies with keys[0].
                tlsAuth = TLSAuth(
                    digest: profile.digest ?? .sha256,
                    sendKey: staticKey.hmacKey2,
                    verifyKey: staticKey.hmacKey1
                )
            } else if let tlsCryptV2 = profile.tlsCryptV2PEM,
                      let decoded = PEMKeyExtractor.extractKey(from: tlsCryptV2),
                      let clientKey = TlsCrypt.ClientKey.parse(decoded: decoded) {
                // tls-crypt-v2: wrap all control packets with the client key.
                tlsCrypt = TlsCrypt(clientKey: clientKey)
            }

            let sessionID = KeyMethod2.randomBytes(8)
            let channel = ControlChannel(
                keyID: 0,
                localSessionID: sessionID,
                tls: tls,
                tlsAuth: tlsAuth,
                tlsCrypt: tlsCrypt,
                sendWire: { [weak self] packet in
                    self?.sendWire(packet)
                }
            )
            channel.debugLog = { [weak self] text in self?.log(text) }
            control = channel

            let options = OptionsString.build(profile: profile)
            clientMaterial = KeyMethod2.makeClientMaterial(
                options: options,
                username: profile.authUserPass?.username,
                password: profile.authUserPass?.password,
                peerInfo: PeerInfo.build()
            )

            channel.sendHardReset()
            startEventSources()
        } catch {
            fail(.tlsSetupFailed("\(error)"))
        }
    }

    private func teardown() {
        timerActive = false
        tickSource?.cancel()
        tickSource = nil
        readSource?.cancel()
        readSource = nil
        tcpWriteSource?.cancel()
        tcpWriteSource = nil
        tcpEstablished = false
        tcpFramer = TCPPacketFramer()
        tcpOutbound = Data()
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        control = nil
        dataCrypto = nil
    }

    // MARK: - Transport

    /// Sends one OpenVPN packet. UDP: a datagram. TCP: length-prefixed
    /// (uint16 big-endian) per the OpenVPN TCP wire format.
    private func sendWire(_ packet: Data) {
        packetObserver?(true, packet)
        guard socketFD >= 0 else { return }
        if profile.transport == .tcp {
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
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.flushTCPOutbound()
            if self.tcpOutbound.isEmpty {
                self.tcpWriteSource?.cancel()
                self.tcpWriteSource = nil
            }
        }
        source.resume()
        tcpWriteSource = source
    }

    private func startEventSources() {
        scheduleTick()
        let read = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        read.setEventHandler { [weak self] in
            self?.drainTransport()
        }
        read.resume()
        readSource = read
    }

    private func scheduleTick() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.25, repeating: 0.25)
        source.setEventHandler { [weak self] in
            guard let self, self.timerActive else { return }
            self.tick()
        }
        source.resume()
        tickSource = source
    }

    private func drainTransport() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        if profile.transport == .tcp {
            while true {
                let n = recv(socketFD, &buffer, buffer.count, 0)
                if n > 0 {
                    do {
                        for packet in try tcpFramer.feed(Data(buffer[0..<n])) {
                            receiveDatagram(packet)
                        }
                    } catch {
                        fail(.protocolError("tcp framing: \(error)"))
                        return
                    }
                    continue
                }
                if n == 0 {
                    fail(.socketError("connection closed by server"))
                    return
                }
                let err = errno
                if err != EAGAIN && err != EWOULDBLOCK {
                    fail(.socketError("tcp recv: \(String(cString: strerror(err)))"))
                }
                return
            }
        }
        while true {
            let n = recv(socketFD, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            receiveDatagram(Data(buffer.prefix(n)))
        }
    }

    private func receiveDatagram(_ packet: Data) {
        lastReceiveTime = Date().timeIntervalSince1970
        packetObserver?(false, packet)
        processIncoming(packet)
    }

    // MARK: - State machine

    private func processIncoming(_ packet: Data) {
        let (opcode, _) = PacketHeader.decode(packet[0])
        if opcode == .controlSoftResetV1 {
            // The server wants to rekey. Without soft-reset support the
            // correct production behavior is a transparent session
            // re-establishment (a couple of seconds of downtime; the utun
            // and the apps' connections survive it).
            log("server soft reset: refreshing session")
            reconnect()
            return
        }
        if opcode.isData {
            handleDataPacket(packet)
            return
        }

        guard let channel = control else { return }
        do {
            let messages = try channel.receive(packet)
            for message in messages {
                handleControlMessage(message)
            }
            // TLS handshake may have completed as a side effect. Before
            // trusting the channel, the peer certificate must pass the
            // profile's remote-cert-tls / verify-x509-name checks.
            if !sentKeyMaterial, channel.tls.isHandshaken {
                try channel.tls.verifyPeer(
                    requireServerEKU: profile.remoteCertTLS == .server,
                    name: requestedNameMatch()
                )
                log("peer verified: \(channel.tls.peerSubject ?? "<no subject>")")
                sendKeyMaterial()
            }
        } catch let error as TLSEngineError {
            if case .peerVerificationFailed(let reason) = error {
                fail(.tlsSetupFailed("peer verification failed: \(reason)"))
            } else {
                fail(.tlsSetupFailed("\(error)"))
            }
        } catch ControlChannelError.malformedPacket {
            // Unauthenticated garbage (e.g. tls-auth HMAC failure): drop
            // the datagram, keep the session, as OpenVPN does.
            log("control: dropped malformed packet")
        } catch {
            fail(.protocolError("control channel error: \(error)"))
        }
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

    private func handleControlMessage(_ message: Data) {
        if message == Self.pingString {
            return
        }
        let text = String(data: message, encoding: .utf8)
        if verboseLogging {
            log("message: \(message.count) bytes, text: \(text.map { String($0.prefix(600)) } ?? "<binary>")")
        }
        switch state {
        case .connecting, .authenticating:
            if let server = KeyMethod2.parse(server: message) {
                if verboseLogging {
                    log("server options: \(server.options)")
                }
                serverMaterial = server
                state = .derivingKeys
                deriveMaterials()
            } else if let text, text.hasPrefix("AUTH_FAILED") {
                fail(.authFailed(String(text.dropFirst("AUTH_FAILED,".count))))
            }
        case .waitPush:
            if let text, text.hasPrefix("PUSH_REPLY,") {
                handlePushReply(message)
            }
        default:
            if let text {
                handleServerMessage(text)
            }
        }
    }

    private func handleServerMessage(_ text: String) {
        guard let message = try? PushParser.parseReply(Data(text.utf8)) else { return }
        switch message {
        case .authFailed(let reason):
            fail(.authFailed(reason))
        case .restart(let reason):
            fail(.serverRestart(reason))
        case .halt:
            fail(.serverHalt)
        case .info, .reply, .other:
            break
        }
    }

    private func sendKeyMaterial() {
        guard let channel = control, let material = clientMaterial else { return }
        sentKeyMaterial = true
        do {
            try channel.sendMessage(KeyMethod2.encode(client: material))
            state = .authenticating
        } catch {
            fail(.protocolError("key material send failed: \(error)"))
        }
    }

    /// Derives the key material with both methods. The actual choice
    /// (EKM vs classic PRF) happens when the PUSH_REPLY arrives —
    /// OpenVPN likewise imports the pushed options before generating
    /// the data channel keys.
    private func deriveMaterials() {
        guard let channel = control,
              let client = clientMaterial,
              let server = serverMaterial else {
            fail(.protocolError("missing key material"))
            return
        }

        if preferTLSKeyExport {
            ekmMaterial = try? KeyExpansion.deriveExporter(tls: channel.tls)
            if ekmMaterial == nil {
                log("exporter unavailable, EKM disabled")
            }
        }
        prfMaterial = KeyExpansion.derivePRF(
            client: client, server: server,
            clientSessionID: channel.localSessionID,
            serverSessionID: channel.remoteSessionID ?? Data(count: 8)
        )
        guard prfMaterial != nil else {
            fail(.keyDerivationFailed)
            return
        }

        state = .waitPush
        pushRequestAttempts = 0
        channel.sendAckIfNeeded(now: Date().timeIntervalSince1970)
        requestPush()
    }

    private func requestPush() {
        guard let channel = control else { return }
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

    private func handlePushReply(_ message: Data) {
        guard case .reply(let pushed) = (try? PushParser.parseReply(message)) ?? .other("") else {
            fail(.protocolError("malformed PUSH_REPLY"))
            return
        }

        pushedOptions = pushed
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
        if let ping = pushed.pingSeconds {
            pingInterval = TimeInterval(ping)
        }
        if let restart = pushed.pingRestartSeconds {
            pingRestart = TimeInterval(restart)
        }
        if let reneg = pushed.renegSeconds, reneg > 0 {
            // Refresh the session slightly before the server's own
            // renegotiation timer fires.
            sessionDeadline = Date().timeIntervalSince1970 + max(60, TimeInterval(reneg - 30))
            log("server reneg-sec \(reneg): session refresh scheduled")
        } else {
            sessionDeadline = nil
        }
        reconnectAttempt = 0

        // The push decides the key derivation method and the cipher —
        // exactly OpenVPN's "import pushed options, then generate keys".
        let material: Data
        if pushed.useTLSKeyExport {
            guard let ekm = ekmMaterial else {
                // The server demands EKM; refusing to fall back would
                // silently produce a key mismatch.
                fail(.keyDerivationFailed)
                return
            }
            material = ekm
            log("key derivation: tls-ekm (pushed)")
        } else {
            guard let prf = prfMaterial else {
                fail(.keyDerivationFailed)
                return
            }
            material = prf
            log("key derivation: OpenVPN PRF")
        }

        guard let keySet = KeyExpansion.keySet(
            material: material,
            cipher: negotiatedCipher,
            digest: negotiatedDigest
        ) else {
            fail(.keyDerivationFailed)
            return
        }

        var epochKeys: DataChannelEpochKeySet? = nil
        if pushed.aeadEpoch {
            epochKeys = KeyExpansion.epochKeySet(material: material, cipher: negotiatedCipher)
            if epochKeys == nil {
                fail(.keyDerivationFailed)
                return
            }
            log("data channel: aead-epoch format")
        }

        dataCrypto = DataChannelCrypto(
            keys: keySet,
            epochKeys: epochKeys,
            replay: profile.replayWindow.map { ReplayWindow(windowSize: $0) } ?? ReplayWindow()
        )
        sendCounter = 0
        peerDataV1 = false

        state = .ready
        log("connection ready (peer-id \(peerID), cipher \(negotiatedCipher.rawValue))")
    }

    // MARK: - Data channel

    /// Sends an IP packet through the tunnel. Safe to call from any queue;
    /// the work is serialized on the connection queue.
    public func sendIPPacket(_ payload: Data) {
        queue.async { [weak self] in
            self?.sendIPPacketLocked(payload)
        }
    }

    private func sendIPPacketLocked(_ payload: Data) {
        guard var crypto = dataCrypto, state == .ready else { return }
        sendCounter &+= 1
        // Classic formats carry a 32-bit packet-id that is part of the
        // AEAD nonce: wrapping it would reuse nonces. Refresh the session
        // well before that point (epoch format has 2^48 and needs nothing).
        if !crypto.usesEpoch, sendCounter >= Self.dataChannelRenewalThreshold {
            log("approaching data-channel packet-id limit: refreshing session")
            reconnect()
            return
        }
        if !crypto.usesEpoch, sendCounter > UInt64(UInt32.max) {
            fail(.protocolError("data-channel packet-id exhausted"))
            return
        }
        do {
            let packet = try crypto.encrypt(
                plaintext: payload,
                packetID: sendCounter,
                peerID: peerID,
                keyID: 0,
                useV1Header: peerDataV1
            )
            dataCrypto = crypto
            sendWire(packet)
        } catch {
            log("data encrypt error: \(error)")
        }
    }

    private func handleDataPacket(_ packet: Data) {
        guard var crypto = dataCrypto else { return }
        let (opcode, _) = PacketHeader.decode(packet[packet.startIndex])
        if opcode == .dataV1 {
            peerDataV1 = true
        }
        do {
            let plaintext = try crypto.decrypt(packet, keyID: 0)
            dataCrypto = crypto
            if plaintext == Self.pingString {
                log("data: received ping (data channel alive)")
                return
            }
            delegate?.connection(self, didReceiveIPPacket: plaintext)
        } catch {
            // Replayed or malformed packets are dropped silently; the
            // replay filter is not advanced for them.
            if case DataChannelError.replayedPacket = error {
                log("data: dropped replayed packet")
            } else {
                log("data decrypt error: \(error)")
            }
        }
    }

    // MARK: - Timers

    private var tickCount = 0
    private func tick() {
        guard let channel = control else {
            return
        }
        tickCount += 1
        let now = Date().timeIntervalSince1970

        if channel.handshakeTimedOut, state != .ready {
            log("handshake timed out")
            fail(.handshakeTimeout)
            return
        }

        if channel.retransmitDue(now: now) {
            log("retransmitted")
            return
        }
        channel.sendAckIfNeeded(now: now)
        if state == .waitPush {
            // The official client re-sends PUSH_REQUEST every second; a
            // single request is not sufficient on every server.
            if now - lastPushRequestAt >= 1.0, pushRequestAttempts < Self.maxPushRequestAttempts {
                log("re-sending PUSH_REQUEST (attempt \(pushRequestAttempts + 1))")
                requestPush()
            } else if pushRequestAttempts >= Self.maxPushRequestAttempts,
                      now - lastPushRequestAt > 5.0 {
                // All attempts answered with silence: give up this round
                // and let the reconnect loop try again.
                log("no PUSH_REPLY after \(pushRequestAttempts) requests")
                reconnect()
                return
            }
        }
        if state == .ready {
            // Keepalive: send the OpenVPN ping string when idle.
            if now - lastPingSend >= pingInterval {
                sendIPPacket(Self.pingString)
                lastPingSend = now
            }
            if now - lastReceiveTime > pingRestart {
                log("ping restart timeout")
                reconnect()
                return
            }
            if let deadline = sessionDeadline, now > deadline {
                log("renegotiation deadline reached: refreshing session")
                reconnect()
                return
            }
        }
    }

    private func reconnect() {
        teardown()
        reconnectAttempt += 1
        // Exponential backoff: 1s, 2s, 4s, ... capped at 30s.
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt - 1)))
        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        state = .reconnecting
        log("reconnecting in \(Int(delay))s (attempt \(reconnectAttempt))")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.wantsConnection,
                  self.reconnectGeneration == generation else { return }
            self.doConnect()
        }
    }

    private func fail(_ error: ConnectionError) {
        log("error: \(error)")
        teardown()
        switch error {
        case .invalidProfile, .authFailed, .tlsSetupFailed, .keyDerivationFailed, .protocolError, .disconnected:
            // Permanent: retrying cannot help (bad credentials, bad
            // profile, certificate mismatch, protocol bugs).
            state = .failed("\(error)")
        case .socketError, .handshakeTimeout, .serverRestart, .serverHalt:
            // Transient: keep the VPN up by reconnecting with backoff.
            if wantsConnection {
                reconnect()
            } else {
                state = .failed("\(error)")
            }
        }
    }

    private func log(_ message: String) {
        delegate?.connection(self, log: message)
    }

    // MARK: - Helpers

    private enum ResolvedRemote {
        case ipv4(sockaddr_in)
        case ipv6(sockaddr_in6)
    }

    private func resolveRemote(_ host: String, port: Int, stream: Bool) -> ResolvedRemote? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = stream ? SOCK_STREAM : SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &result) == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var v4Candidate: sockaddr_in?
        var v6Candidate: sockaddr_in6?
        while let current = cursor {
            if current.pointee.ai_family == AF_INET, let addr = current.pointee.ai_addr {
                if v4Candidate == nil {
                    v4Candidate = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                }
            } else if current.pointee.ai_family == AF_INET6, let addr = current.pointee.ai_addr {
                if v6Candidate == nil {
                    v6Candidate = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                }
            }
            cursor = current.pointee.ai_next
        }
        if let v4 = v4Candidate {
            return .ipv4(v4)
        }
        if let v6 = v6Candidate {
            return .ipv6(v6)
        }
        return nil
    }
}
