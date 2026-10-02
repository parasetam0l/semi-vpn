import Foundation

public enum ControlChannelError: Error, Sendable, Equatable {
    case handshakeTimeout
    case tlsFailed(String)
    case malformedPacket
    case messageTooLarge
    case sessionClosed
}

/// A pending outgoing control packet awaiting acknowledgement.
struct SendEntry: Sendable {
    var packetID: UInt32
    var opcode: OpenVPNOpcode
    var payload: Data       // fragment bytes (TLS ciphertext chunk)
    var nextTry: TimeInterval
    var timeout: TimeInterval
    var acked: Bool
    /// When the packet was first transmitted (nil until sent).
    var firstSent: TimeInterval? = nil
}

/// Control-channel packet protection shared by every key state of a
/// session: tls-auth, tls-crypt or tls-crypt-v2, plus the dynamic tls-crypt
/// key OpenVPN 2.6+ uses for renegotiations (key-id > 0) when both peers
/// announce it. The wrapping packet-ids and replay windows live here
/// because OpenVPN keeps them per session, not per key.
///
/// Wire formats (verified against OpenVPN 2.6/2.7 source and wire captures):
///
/// Plain:      [opcode(1)][sid(8)][acks][pid(4)][payload]
/// tls-auth:   [opcode(1)][sid(8)][hmac(n)][tpid(8)][acks][pid(4)][payload]
/// tls-crypt:  [opcode(1)][sid(8)][pid(8)][tag(32)][ct][WKc on reset/first]
public final class ControlWrapper: @unchecked Sendable {
    public private(set) var tlsAuth: TLSAuth?
    public private(set) var tlsCrypt: TlsCrypt?
    /// Dynamic tls-crypt for key-id > 0 (`protocol-flags dyn-tls-crypt`).
    public private(set) var renegotiationCrypt: TlsCrypt?
    /// The 256-byte static/client key, XORed into the dynamic key.
    private let originalKeyMaterial: Data?
    private var replay = ReplayWindow()
    private var renegotiationReplay = ReplayWindow()

    public init(tlsAuth: TLSAuth? = nil, tlsCrypt: TlsCrypt? = nil, originalKeyMaterial: Data? = nil) {
        self.tlsAuth = tlsAuth
        self.tlsCrypt = tlsCrypt
        self.originalKeyMaterial = originalKeyMaterial
    }

    /// tls-crypt-v2 announces itself with P_CONTROL_HARD_RESET_CLIENT_V3 and
    /// carries the wrapped client key; tls-crypt v1 does neither.
    public var usesTlsCryptV2: Bool { tlsCrypt?.isV2 == true }

    /// Installs the dynamic tls-crypt key from the 256 bytes exported with
    /// `EXPORTER-OpenVPN-dynamic-tls-crypt` (OpenVPN
    /// `tls_session_generate_dynamic_tls_crypt_key`): XORed with the
    /// original wrapping key when one is configured, client direction
    /// inverse (send keys[1], receive keys[0]), AES-256-CTR + HMAC-SHA256.
    public func enableDynamicTlsCrypt(exportedKey: Data) {
        guard exportedKey.count == TlsCrypt.keyMaterialLength else { return }
        var key = exportedKey
        if let original = originalKeyMaterial, original.count == key.count {
            key = Data(zip(key, original).map { $0 ^ $1 })
        }
        renegotiationCrypt = TlsCrypt(clientKey: .init(kc: key, wkc: Data()), initialPacketID: 0)
        renegotiationReplay = ReplayWindow()
    }

    /// Wraps a plain `[opcode][sid]` header and body into the wire packet.
    func wrap(header: Data, body: Data, keyID: UInt8, appendWKc: Bool) -> Data {
        if keyID > 0, var crypt = renegotiationCrypt {
            let wrapped = (try? crypt.wrap(header: header, body: body)) ?? Data()
            renegotiationCrypt = crypt
            return header + wrapped
        }
        if var tlsAuth {
            // tls-auth: HMAC over the whole packet, inserted after the sid,
            // followed by the transport packet-id.
            let packet = tlsAuth.wrap(packet: header + body) ?? (header + body)
            self.tlsAuth = tlsAuth
            return packet
        }
        if var tlsCrypt {
            var packet = header
            packet.append((try? tlsCrypt.wrap(header: header, body: body)) ?? Data())
            if appendWKc, tlsCrypt.isV2 {
                packet.append(tlsCrypt.clientKey.wkc)
            }
            self.tlsCrypt = tlsCrypt
            return packet
        }
        return header + body
    }

    /// Verifies and unwraps a wire packet into `[opcode][sid][body]`,
    /// rejecting forgeries and replays.
    func unwrap(_ wire: Data) throws -> Data {
        let wire = Data(wire)
        guard wire.count >= 9 else { throw ControlChannelError.malformedPacket }
        let keyID = wire[0] & 0x07
        if keyID > 0, let crypt = renegotiationCrypt {
            guard let body = try? crypt.unwrap(header: Data(wire.prefix(9)), data: wire.dropFirst(9)) else {
                throw ControlChannelError.malformedPacket
            }
            try checkReplay(wire.subdata(in: 9..<17), window: &renegotiationReplay)
            return wire.prefix(9) + body
        }
        if let tlsAuth {
            guard let unwrapped = tlsAuth.unwrap(wire) else {
                throw ControlChannelError.malformedPacket
            }
            try checkReplay(wire.subdata(in: (9 + tlsAuth.tagLength)..<(9 + tlsAuth.tagLength + 8)), window: &replay)
            return unwrapped
        }
        if let tlsCrypt {
            guard let body = try? tlsCrypt.unwrap(header: Data(wire.prefix(9)), data: wire.dropFirst(9)) else {
                throw ControlChannelError.malformedPacket
            }
            try checkReplay(wire.subdata(in: 9..<17), window: &replay)
            return wire.prefix(9) + body
        }
        return wire
    }

    /// Rejects replayed wrapped packets (`time << 32 | id`). Only called
    /// after the packet authenticated, so forgeries cannot advance it.
    private func checkReplay(_ pid: Data, window: inout ReplayWindow) throws {
        let value = pid.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard window.accept(value) else {
            throw ControlChannelError.malformedPacket
        }
    }

    /// Authenticates a packet without consuming its replay slot.
    func isAuthentic(_ wire: Data) -> Bool {
        let wire = Data(wire)
        guard wire.count >= 9 else { return false }
        let keyID = wire[0] & 0x07
        if keyID > 0, let crypt = renegotiationCrypt {
            return (try? crypt.unwrap(header: Data(wire.prefix(9)), data: wire.dropFirst(9))) != nil
        }
        if let tlsAuth { return tlsAuth.unwrap(wire) != nil }
        if let tlsCrypt {
            return (try? tlsCrypt.unwrap(header: Data(wire.prefix(9)), data: wire.dropFirst(9))) != nil
        }
        return true
    }
}

/// The reliable control-channel transport of one key state (key-id).
///
/// Implements the OpenVPN reliable layer over UDP: monotonically increasing
/// packet-ids per direction, ACK vectors piggybacked on outgoing packets,
/// retransmission with exponential backoff, and ordered delivery of TLS
/// ciphertext to the TLS engine. A session starts with key-id 0 (hard
/// reset); every renegotiation runs a new channel on the next key-id that
/// starts with P_CONTROL_SOFT_RESET_V1.
public final class ControlChannel: @unchecked Sendable {
    static let maxFragmentLength = 1200
    /// OpenVPN's CONTROL_SEND_ACK_MAX.
    static let maxAcksPerPacket = 4
    /// Packets in flight before an acknowledgement is required
    /// (TLS_RELIABLE_N_SEND_BUFFERS; the peer buffers 12 out of order).
    static let sendWindow = 6
    /// Out-of-order packets buffered ahead of the next expected one.
    static let receiveWindow: UInt32 = 64
    static let maxRetransmitTimeout: TimeInterval = 8
    static let initialTimeout: TimeInterval = 1.0
    static let ackCoalesce: TimeInterval = 0.2

    public let keyID: UInt8
    public let localSessionID: Data
    public private(set) var remoteSessionID: Data?

    public var tls: TLSEngine
    public let wrapper: ControlWrapper
    /// The opcode of this key state's first packet.
    let initialOpcode: OpenVPNOpcode
    /// True when the peer requested the WKc to be resent with the first
    /// data packet (P_CONTROL_WKC_V1), per the early-negotiation TLV.
    public private(set) var peerRequestsWKCResend = false

    private var sendQueue: [SendEntry] = []
    private var nextSendPacketID: UInt32 = 1
    private var nextRecvPacketID: UInt32 = 0
    private var outOfOrder: [UInt32: Data] = [:]
    /// Received packet-ids not yet acknowledged, oldest first.
    private var pendingAcks: [UInt32] = []
    /// Recently sent acks, newest first (OpenVPN's ack_mru), repeated to
    /// fill each packet's ack vector in case earlier acks were lost.
    private var recentAcks: [UInt32] = []
    private var lastAckSent: TimeInterval = 0
    private var sentWKCOnce = false

    private let sendWire: (Data) -> Void

    /// - Parameter remoteSessionID: known for renegotiations (soft reset),
    ///   learned from the server's hard reset otherwise.
    /// - Parameter softReset: start with P_CONTROL_SOFT_RESET_V1 instead of
    ///   a hard reset.
    public init(
        keyID: UInt8,
        localSessionID: Data,
        remoteSessionID: Data? = nil,
        tls: TLSEngine,
        wrapper: ControlWrapper,
        softReset: Bool = false,
        sendWire: @escaping (Data) -> Void
    ) {
        self.keyID = keyID
        self.localSessionID = localSessionID
        self.remoteSessionID = remoteSessionID
        self.tls = tls
        self.wrapper = wrapper
        if softReset {
            initialOpcode = .controlSoftResetV1
        } else {
            initialOpcode = wrapper.usesTlsCryptV2 ? .controlHardResetClientV3 : .controlHardResetClientV2
        }
        self.sendWire = sendWire
    }

    public convenience init(
        keyID: UInt8,
        localSessionID: Data,
        tls: TLSEngine,
        tlsAuth: TLSAuth?,
        tlsCrypt: TlsCrypt?,
        sendWire: @escaping (Data) -> Void
    ) {
        self.init(
            keyID: keyID,
            localSessionID: localSessionID,
            tls: tls,
            wrapper: ControlWrapper(tlsAuth: tlsAuth, tlsCrypt: tlsCrypt),
            sendWire: sendWire
        )
    }

    // MARK: - Sending

    /// Queues and sends this key state's initial reset packet (pid 0):
    /// the hard reset of a new session or the soft reset of a
    /// renegotiation.
    ///
    /// Per OpenVPN, the client's *first* packet carries an empty ACK vector
    /// (ack-count 0). With tls-crypt-v2 the hard reset is opcode V3 and has
    /// the wrapped client key appended.
    public func sendReset() {
        let entry = SendEntry(
            packetID: 0,
            opcode: initialOpcode,
            payload: Data(),
            nextTry: 0,
            timeout: Self.initialTimeout,
            acked: false
        )
        sendQueue.append(entry)
        flushSendQueue()
    }

    /// Feeds a plaintext application message into TLS and queues the
    /// resulting ciphertext fragments for reliable delivery.
    public func sendMessage(_ message: Data) throws {
        debugLog("writePlaintext: \(message.count) bytes")
        _ = try tls.writePlaintext(message)
        drainTLSOutput()
    }

    /// Drains pending TLS ciphertext into queued fragments.
    private func drainTLSOutput() {
        let ciphertext = tls.drainCiphertext()
        debugLog("drain: \(ciphertext.count) bytes")
        guard !ciphertext.isEmpty else { return }

        // The wire packet must fit the tunnel MTU. For tls-crypt the
        // overhead is opcode+sid (9) + pid (8) + tag (32) + acks (~17),
        // plus the appended WKC on the first data packet.
        var maxFragment = 1400 - 9 - 8 - 32 - 17
        if peerRequestsWKCResend, !sentWKCOnce, wrapper.usesTlsCryptV2 {
            maxFragment -= 299   // WKC
        }
        maxFragment = max(256, min(maxFragment, Self.maxFragmentLength))

        var offset = 0
        while offset < ciphertext.count {
            let chunk = ciphertext.dropFirst(offset).prefix(maxFragment)
            let entry = SendEntry(
                packetID: nextSendPacketID,
                opcode: .controlV1,
                payload: Data(chunk),
                nextTry: 0,
                timeout: Self.initialTimeout,
                acked: false
            )
            nextSendPacketID += 1
            sendQueue.append(entry)
            offset += chunk.count
        }
        flushSendQueue()
    }

    /// Sends every packet in the send window that has not been sent yet.
    private func flushSendQueue() {
        let now = Date().timeIntervalSince1970
        for index in sendQueue.indices.prefix(Self.sendWindow) where sendQueue[index].firstSent == nil {
            sendQueue[index].firstSent = now
            sendQueue[index].nextTry = now + sendQueue[index].timeout
            sendWire(buildPacket(at: index))
        }
    }

    /// The ack vector for the next packet: up to four pending acks (oldest
    /// first; the rest wait for the next packet), topped up with recently
    /// sent ones, as OpenVPN's reliable_ack_write does.
    private func takeAcks() -> [UInt32] {
        let fresh = Array(pendingAcks.prefix(Self.maxAcksPerPacket))
        pendingAcks.removeFirst(fresh.count)
        recentAcks = fresh.reversed() + recentAcks.filter { !fresh.contains($0) }
        recentAcks = Array(recentAcks.prefix(8))
        var acks = fresh
        for ack in recentAcks where acks.count < Self.maxAcksPerPacket && !acks.contains(ack) {
            acks.append(ack)
        }
        return acks
    }

    private func buildPacket(at index: Int) -> Data {
        // OpenVPN repeats recently sent acks (lru_acks) on every packet.
        let entry = sendQueue[index]
        let acks = takeAcks()
        lastAckSent = Date().timeIntervalSince1970

        let body = ControlPacketBody(
            ackPacketIDs: acks,
            ackRemoteSessionID: acks.isEmpty ? nil : remoteSessionID,
            packetID: entry.packetID,
            payload: entry.payload
        ).encoded

        // The first control packet after a WKc-resend request carries the
        // wrapped client key (and keeps it on retransmission).
        if sendQueue[index].opcode == .controlV1,
           peerRequestsWKCResend,
           !sentWKCOnce,
           wrapper.usesTlsCryptV2 {
            sendQueue[index].opcode = .controlWKCv1
            sentWKCOnce = true
        }
        let opcode = sendQueue[index].opcode

        var header = Data()
        header.append(PacketHeader.encode(opcode: opcode, keyID: keyID))
        header.append(localSessionID)
        return wrapper.wrap(
            header: header,
            body: body,
            keyID: keyID,
            appendWKc: opcode == .controlHardResetClientV3 || opcode == .controlWKCv1
        )
    }

    /// Sends pure P_ACKs for unacknowledged received packets (several when
    /// more than four are pending).
    public func sendAckIfNeeded(now: TimeInterval) {
        guard !pendingAcks.isEmpty, now - lastAckSent > Self.ackCoalesce else { return }
        while !pendingAcks.isEmpty {
            sendAck()
        }
        lastAckSent = now
    }

    private func sendAck() {
        let acks = takeAcks()

        let body = ControlPacketBody(
            ackPacketIDs: acks,
            ackRemoteSessionID: remoteSessionID,
            packetID: 0,
            payload: Data()
        ).encodedAcksOnly

        var header = Data()
        header.append(PacketHeader.encode(opcode: .ackV1, keyID: keyID))
        header.append(localSessionID)
        sendWire(wrapper.wrap(header: header, body: body, keyID: keyID, appendWKc: false))
    }

    // MARK: - Receiving

    /// Processes one received datagram (the raw wire packet).
    /// Returns any complete plaintext messages extracted from TLS.
    public func receive(_ wire: Data) throws -> [Data] {
        let packet = try wrapper.unwrap(wire)
        guard packet.count >= 9 else { throw ControlChannelError.malformedPacket }

        let (opcode, _) = PacketHeader.decode(packet[0])
        let sid = packet.subdata(in: 1..<9)

        if opcode == .controlHardResetServerV1 || opcode == .controlHardResetServerV2 {
            remoteSessionID = sid
        } else if let remote = remoteSessionID, remote != sid {
            return []   // stale or forged packet from another session
        }

        guard let body = ControlPacketBody.parse(
            packet.dropFirst(9),
            hasPacketID: opcode != .ackV1
        ) else {
            throw ControlChannelError.malformedPacket
        }

        // Process ACKs of our packets.
        if !body.ackPacketIDs.isEmpty {
            let ackedSet = Set(body.ackPacketIDs)
            for index in sendQueue.indices where ackedSet.contains(sendQueue[index].packetID) {
                sendQueue[index].acked = true
            }
            sendQueue.removeAll(where: { $0.acked })
            // Acknowledged packets freed up the window: send what fits.
            flushSendQueue()
        }

        // Acknowledge this packet unless it is beyond our receive window
        // (it will be retransmitted). P_ACK packets carry no payload and no
        // own packet-id (the parsed value is a placeholder zero) — they
        // must not be acknowledged.
        if opcode != .ackV1,
           body.packetID < nextRecvPacketID &+ Self.receiveWindow,
           !pendingAcks.contains(body.packetID) {
            pendingAcks.append(body.packetID)
        }

        if opcode.isControl {
            try acceptReliablePacket(opcode: opcode, pid: body.packetID, payload: body.payload)
        }

        // Drive the TLS state machine.
        if !tls.isHandshaken {
            _ = try tls.handshake()
        }
        drainTLSOutput()

        var messages: [Data] = []
        while let message = try tls.readPlaintext() {
            debugLog("read message \(message.count)B: \(String(data: message.prefix(40), encoding: .utf8) ?? "binary")")
            messages.append(message)
        }
        return messages
    }

    /// Buffers out-of-order fragments and feeds complete, in-order
    /// ciphertext to TLS. Reset packets (pid 0) carry early-negotiation
    /// TLVs, which are parsed (and skipped) rather than fed to TLS.
    private func acceptReliablePacket(opcode: OpenVPNOpcode, pid: UInt32, payload: Data) throws {
        if (opcode.isHardReset || opcode == .controlSoftResetV1) && pid == 0 {
            if opcode.isHardReset {
                peerRequestsWKCResend = parseEarlyNegotiation(payload)
            }
            nextRecvPacketID = max(nextRecvPacketID, 1)
            return
        }
        if pid == nextRecvPacketID {
            try feedCiphertext(payload)
            nextRecvPacketID += 1
            while let buffered = outOfOrder[nextRecvPacketID] {
                try feedCiphertext(buffered)
                outOfOrder.removeValue(forKey: nextRecvPacketID)
                nextRecvPacketID += 1
            }
        } else if pid > nextRecvPacketID, pid < nextRecvPacketID &+ Self.receiveWindow {
            outOfOrder[pid] = payload
        }
        // Duplicates (pid < next) are dropped silently, as OpenVPN does.
    }

    /// Parses the reset packet's early-negotiation TLVs:
    /// `[type u16][len u16][data]`. Returns true when the
    /// `EARLY_NEG_FLAG_RESEND_WKC` flag is present.
    private func parseEarlyNegotiation(_ data: Data) -> Bool {
        let data = Data(data)
        var cursor = 0
        var resendWKC = false
        while cursor + 4 <= data.count {
            let type = UInt16(data[cursor]) << 8 | UInt16(data[cursor + 1])
            let len = Int(UInt16(data[cursor + 2]) << 8 | UInt16(data[cursor + 3]))
            cursor += 4
            guard cursor + len <= data.count else { break }
            if type == 0x0001 {  // TLV_TYPE_EARLY_NEG_FLAGS
                if len >= 2 {
                    let flags = UInt16(data[cursor]) << 8 | UInt16(data[cursor + 1])
                    if flags & 0x0001 != 0 {  // EARLY_NEG_FLAG_RESEND_WKC
                        resendWKC = true
                    }
                }
            }
            cursor += len
        }
        return resendWKC
    }

    private func feedCiphertext(_ payload: Data) throws {
        guard !payload.isEmpty else { return }
        tls.feedCiphertext(payload)
        debugLog("fed \(payload.count) TLS bytes (handshaken: \(tls.isHandshaken))")
        if !tls.isHandshaken {
            _ = try tls.handshake()
        }
    }

    /// Diagnostics hook for the connection layer.
    var debugLog: (String) -> Void = { _ in }

    // MARK: - Housekeeping

    /// Retransmits every packet in the send window whose timer elapsed,
    /// with exponential backoff. Returns true when anything was sent.
    @discardableResult
    public func retransmitDue(now: TimeInterval) -> Bool {
        var sent = false
        for index in sendQueue.indices.prefix(Self.sendWindow) where sendQueue[index].nextTry <= now {
            if sendQueue[index].firstSent == nil {
                sendQueue[index].firstSent = now
            } else {
                sendQueue[index].timeout = min(sendQueue[index].timeout * 2, Self.maxRetransmitTimeout)
            }
            sendQueue[index].nextTry = now + sendQueue[index].timeout
            sendWire(buildPacket(at: index))
            sent = true
        }
        return sent
    }

    /// True when a packet has stayed unacknowledged for longer than
    /// `window` seconds since it was first sent: the peer is gone or the
    /// control channel is broken (OpenVPN's "TLS key negotiation failed").
    public func handshakeTimedOut(now: TimeInterval, window: TimeInterval) -> Bool {
        sendQueue.contains { entry in
            guard !entry.acked, let firstSent = entry.firstSent else { return false }
            return now - firstSent > window
        }
    }

    /// Checks that a raw packet is authentic for this session (wrapping
    /// HMAC/AEAD and session-id) without processing it. Used before acting
    /// on packets that change state outside the reliable layer.
    public func isAuthentic(_ wire: Data) -> Bool {
        let wire = Data(wire)
        guard wire.count >= 9, wrapper.isAuthentic(wire), let remoteSessionID else { return false }
        return wire.subdata(in: 1..<9) == remoteSessionID
    }

    public var hasUnackedPackets: Bool {
        sendQueue.contains(where: { !$0.acked })
    }
}
