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
}

/// The reliable control-channel transport.
///
/// Implements the OpenVPN reliable layer over UDP: monotonically increasing
/// packet-ids per direction, ACK vectors piggybacked on outgoing packets,
/// retransmission with exponential backoff, and ordered delivery of TLS
/// ciphertext to the TLS engine.
///
/// Wire formats (verified against OpenVPN 2.6/2.7 source and wire captures):
///
/// Plain:      [opcode(1)][sid(8)][acks][pid(4)][payload]
/// tls-auth:   [opcode(1)][sid(8)][hmac(32)][tpid(4)][acks][pid(4)][payload]
/// tls-crypt:  [opcode(1)][sid(8)][pid(8)][tag(32)][ct][WKc on reset/first]
public final class ControlChannel: @unchecked Sendable {
    static let maxFragmentLength = 1200
    static let maxAcksPerPacket = 4
    static let handshakeWindow: TimeInterval = 60
    static let initialTimeout: TimeInterval = 1.0
    static let ackCoalesce: TimeInterval = 0.2

    public let keyID: UInt8
    public let localSessionID: Data
    public private(set) var remoteSessionID: Data?

    public var tls: TLSEngine
    /// Stored by reference: mutations (e.g. the tls-crypt wrap packet-id
    /// counter) must persist across calls.
    public var tlsAuth: TLSAuth?
    public var tlsCrypt: TlsCrypt?
    /// True when the peer requested the WKc to be resent with the first
    /// data packet (P_CONTROL_WKC_V1), per the early-negotiation TLV.
    public private(set) var peerRequestsWKCResend = false

    private var sendQueue: [SendEntry] = []
    private var nextSendPacketID: UInt32 = 1
    private var nextRecvPacketID: UInt32 = 0
    private var outOfOrder: [UInt32: Data] = [:]
    private var pendingAcks: [UInt32] = []
    private var lruAcks: [UInt32] = []
    private var lastAckSent: TimeInterval = 0
    private var sentWKCOnce = false

    private let sendWire: (Data) -> Void

    public init(
        keyID: UInt8,
        localSessionID: Data,
        tls: TLSEngine,
        tlsAuth: TLSAuth?,
        tlsCrypt: TlsCrypt?,
        sendWire: @escaping (Data) -> Void
    ) {
        self.keyID = keyID
        self.localSessionID = localSessionID
        self.tls = tls
        self.tlsAuth = tlsAuth
        self.tlsCrypt = tlsCrypt
        self.sendWire = sendWire
    }

    var usesTlsCrypt: Bool { tlsCrypt != nil }

    var usesTlsAuth: Bool { tlsAuth != nil }

    // MARK: - Sending

    /// Queues and sends the initial hard-reset packet (pid 0).
    ///
    /// Per OpenVPN, the client's *first* packet carries an empty ACK vector
    /// (ack-count 0). With tls-crypt-v2 the reset is opcode V3 and has the
    /// wrapped client key appended.
    public func sendHardReset() {
        let opcode: OpenVPNOpcode = usesTlsCrypt ? .controlHardResetClientV3 : .controlHardResetClientV2
        let entry = SendEntry(
            packetID: 0,
            opcode: opcode,
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
        if peerRequestsWKCResend, !sentWKCOnce, usesTlsCrypt {
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

    /// Sends the oldest unacked packet, carrying the current ACK vector.
    private func flushSendQueue() {
        guard let index = sendQueue.indices.first(where: { !sendQueue[$0].acked }) else { return }
        sendQueue[index].nextTry = Date().timeIntervalSince1970 + sendQueue[index].timeout
        sendWire(buildPacket(for: sendQueue[index]))
    }

    private func buildPacket(for entry: SendEntry) -> Data {
        // OpenVPN repeats recently sent acks (lru_acks) on every packet.
        let acks = Array((lruAcks + pendingAcks).suffix(Self.maxAcksPerPacket))
        lruAcks = Array(acks.suffix(Self.maxAcksPerPacket))
        pendingAcks.removeAll(keepingCapacity: true)
        lastAckSent = Date().timeIntervalSince1970

        let body = ControlPacketBody(
            ackPacketIDs: acks,
            ackRemoteSessionID: acks.isEmpty ? nil : remoteSessionID,
            packetID: entry.packetID,
            payload: entry.payload
        ).encoded

        var opcode = entry.opcode
        if opcode == .controlV1,
           peerRequestsWKCResend,
           !sentWKCOnce,
           tlsCrypt != nil {
            opcode = .controlWKCv1
        }

        var packet = Data()
        packet.append(PacketHeader.encode(opcode: opcode, keyID: keyID))
        packet.append(localSessionID)

        if var tlsAuth {
            // tls-auth: HMAC over the whole packet, inserted after the sid,
            // followed by the transport packet-id.
            var inner = Data()
            inner.append(PacketHeader.encode(opcode: opcode, keyID: keyID))
            inner.append(localSessionID)
            inner.append(body)
            if let wrapped = tlsAuth.wrap(packet: inner) {
                packet = wrapped
            }
            self.tlsAuth = tlsAuth
        } else if var tlsCrypt {
            let header = Data(packet)
            if let wrapped = try? tlsCrypt.wrap(header: header, body: body) {
                packet.append(wrapped)
            }
            if opcode == .controlHardResetClientV3 || opcode == .controlWKCv1 {
                packet.append(tlsCrypt.clientKey.wkc)
                if opcode == .controlWKCv1 {
                    sentWKCOnce = true
                }
            }
            self.tlsCrypt = tlsCrypt
        } else {
            packet.append(body)
        }
        return packet
    }

    /// Sends a pure P_ACK for any unacknowledged received packets.
    public func sendAckIfNeeded(now: TimeInterval) {
        let acks = Array((lruAcks + pendingAcks).suffix(Self.maxAcksPerPacket))
        guard !acks.isEmpty, now - lastAckSent > Self.ackCoalesce else { return }
        lruAcks = Array(acks.suffix(Self.maxAcksPerPacket))
        pendingAcks.removeAll(keepingCapacity: true)
        lastAckSent = now

        let body = ControlPacketBody(
            ackPacketIDs: acks,
            ackRemoteSessionID: remoteSessionID,
            packetID: 0,
            payload: Data()
        ).encodedAcksOnly

        var packet = Data()
        packet.append(PacketHeader.encode(opcode: .ackV1, keyID: keyID))
        packet.append(localSessionID)

        if var tlsAuth {
            var inner = Data()
            inner.append(PacketHeader.encode(opcode: .ackV1, keyID: keyID))
            inner.append(localSessionID)
            inner.append(body)
            if let wrapped = tlsAuth.wrap(packet: inner) {
                packet = wrapped
            }
            self.tlsAuth = tlsAuth
        } else if var tlsCrypt {
            let header = Data(packet)
            if let wrapped = try? tlsCrypt.wrap(header: header, body: body) {
                packet.append(wrapped)
            }
            self.tlsCrypt = tlsCrypt
        } else {
            packet.append(body)
        }
        sendWire(packet)
    }

    // MARK: - Receiving

    /// Processes one received UDP datagram (the raw wire packet).
    /// Returns any complete plaintext messages extracted from TLS.
    public func receive(_ wire: Data) throws -> [Data] {
        guard wire.count >= 9 else { throw ControlChannelError.malformedPacket }

        let packet: Data
        if let tlsAuth {
            guard let unwrapped = tlsAuth.unwrap(wire) else {
                throw ControlChannelError.malformedPacket
            }
            packet = unwrapped
        } else if let tlsCrypt {
            guard let unwrapped = try? tlsCrypt.unwrap(header: Data(wire.prefix(9)), data: wire.dropFirst(9)) else {
                throw ControlChannelError.malformedPacket
            }
            // Rebuild the plain [opcode][sid] + body for parsing.
            packet = wire.prefix(9) + unwrapped
        } else {
            packet = wire
        }

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
            if let oldest = sendQueue.first,
               !ackedSet.isEmpty,
               oldest.nextTry > Date().timeIntervalSince1970 {
                sendQueue[0].nextTry = 0
            }
            // Acknowledged packets freed up the window: send the next one.
            flushSendQueue()
        }

        // Acknowledge this packet. P_ACK packets carry no payload and no
        // own packet-id (the parsed value is a placeholder zero) — they
        // must not be acknowledged.
        if opcode != .ackV1, !pendingAcks.contains(body.packetID) {
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
        var reads = 0
        while let message = try tls.readPlaintext() {
            reads += 1
            debugLog("read message \(message.count)B: \(String(data: message.prefix(40), encoding: .utf8) ?? "binary")")
            messages.append(message)
        }
        if reads == 0 {
            debugLog("no plaintext after packet (pid \(body.packetID), payload \(body.payload.count)B)")
        }
        return messages
    }

    /// Buffers out-of-order fragments and feeds complete, in-order
    /// ciphertext to TLS. Reset packets (pid 0) carry early-negotiation
    /// TLVs, which are parsed (and skipped) rather than fed to TLS.
    private func acceptReliablePacket(opcode: OpenVPNOpcode, pid: UInt32, payload: Data) throws {
        if opcode.isHardReset && pid == 0 {
            peerRequestsWKCResend = parseEarlyNegotiation(payload)
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
        } else if pid > nextRecvPacketID, pid < nextRecvPacketID + 1024 {
            outOfOrder[pid] = payload
        }
        // Duplicates (pid < next) are dropped silently, as OpenVPN does.
    }

    /// Parses the reset packet's early-negotiation TLVs:
    /// `[type u16][len u16][data]`. Returns true when the
    /// `EARLY_NEG_FLAG_RESEND_WKC` flag is present.
    private func parseEarlyNegotiation(_ data: Data) -> Bool {
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

    /// Retransmits the oldest unacked packet whose timeout has elapsed.
    public func retransmitDue(now: TimeInterval) -> Bool {
        guard let index = sendQueue.indices.first(where: {
            !sendQueue[$0].acked && sendQueue[$0].nextTry <= now
        }) else { return false }
        sendQueue[index].timeout = min(sendQueue[index].timeout * 2, Self.handshakeWindow)
        sendQueue[index].nextTry = now + sendQueue[index].timeout
        sendWire(buildPacket(for: sendQueue[index]))
        return true
    }

    /// True when the oldest unacked packet has exceeded the handshake window.
    public var handshakeTimedOut: Bool {
        guard let oldest = sendQueue.first(where: { !$0.acked }) else { return false }
        return Date().timeIntervalSince1970 > oldest.nextTry + Self.handshakeWindow
    }

    public var hasUnackedPackets: Bool {
        sendQueue.contains(where: { !$0.acked })
    }
}
