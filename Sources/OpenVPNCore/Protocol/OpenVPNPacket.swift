import Foundation

/// OpenVPN wire protocol opcodes (top 5 bits of the first byte).
///
/// Reference: OpenVPN 2.6 source, `src/openvpn/ssl_pkt.h`.
public enum OpenVPNOpcode: UInt8, Sendable {
    case controlHardResetClientV1 = 1
    case controlHardResetServerV1 = 2
    case controlSoftResetV1 = 3
    case controlV1 = 4
    case ackV1 = 5
    case dataV1 = 6
    case controlHardResetClientV2 = 7
    case controlHardResetServerV2 = 8
    case dataV2 = 9
    case controlHardResetClientV3 = 10
    case controlWKCv1 = 11
    case authFailedV1 = 14

    public var isData: Bool {
        switch self {
        case .dataV1, .dataV2: return true
        default: return false
        }
    }

    public var isControl: Bool {
        switch self {
        case .controlV1, .controlSoftResetV1,
             .controlHardResetClientV1, .controlHardResetServerV1,
             .controlHardResetClientV2, .controlHardResetServerV2,
             .controlHardResetClientV3:
            return true
        default: return false
        }
    }

    public var isHardReset: Bool {
        switch self {
        case .controlHardResetClientV1, .controlHardResetServerV1,
             .controlHardResetClientV2, .controlHardResetServerV2,
             .controlHardResetClientV3:
            return true
        default: return false
        }
    }
}

public enum OpenVPNProtocolError: Error, Sendable, Equatable {
    case truncatedPacket
    case badOpcode(UInt8)
    case malformedAck
}

/// The single leading byte: opcode in the high 5 bits, key-id in the low 3.
public enum PacketHeader {
    public static func encode(opcode: OpenVPNOpcode, keyID: UInt8) -> UInt8 {
        (opcode.rawValue << 3) | (keyID & 0x7)
    }

    public static func decode(_ byte: UInt8) -> (opcode: OpenVPNOpcode, keyID: UInt8) {
        let raw = (byte >> 3) & 0x1F
        let opcode = OpenVPNOpcode(rawValue: raw) ?? .dataV1
        return (opcode, byte & 0x7)
    }
}

/// A control-channel packet body: the bytes between the session-id and the
/// payload on the wire, i.e. the ACK vector plus the reliable packet-id.
///
/// On-wire P_CONTROL_V1 (OpenVPN 2.4+; no message-packet-id field anymore):
///
///     [opcode(1)][sid(8)][ack-count(1)][ack-pids(4n)][ack-sid(8)][pid(4)][payload]
///
/// With `tls-auth` enabled the on-wire form additionally carries a 32-byte
/// HMAC and a transport packet-id before the ACK vector (see `TLSAuth`).
public struct ControlPacketBody: Sendable, Equatable {
    public var ackPacketIDs: [UInt32]
    public var ackRemoteSessionID: Data?   // 8 bytes, required when ackPacketIDs non-empty
    public var packetID: UInt32            // reliable-layer sequence number
    public var payload: Data

    public init(ackPacketIDs: [UInt32] = [], ackRemoteSessionID: Data? = nil, packetID: UInt32, payload: Data = Data()) {
        self.ackPacketIDs = ackPacketIDs
        self.ackRemoteSessionID = ackRemoteSessionID
        self.packetID = packetID
        self.payload = payload
    }

    public var encoded: Data {
        var bytes = Data()
        let n = UInt8(ackPacketIDs.count)
        bytes.append(n)
        for ack in ackPacketIDs {
            bytes.append(ack.bigEndianBytes)
        }
        if let remoteSession = ackRemoteSessionID {
            bytes.append(remoteSession)
        }
        bytes.append(packetID.bigEndianBytes)
        bytes.append(payload)
        return bytes
    }

    /// Encodes only the ACK vector (P_ACK_V1 packets carry no packet-id
    /// field and no payload).
    public var encodedAcksOnly: Data {
        var bytes = Data()
        let n = UInt8(ackPacketIDs.count)
        bytes.append(n)
        for ack in ackPacketIDs {
            bytes.append(ack.bigEndianBytes)
        }
        if let remoteSession = ackRemoteSessionID {
            bytes.append(remoteSession)
        }
        return bytes
    }

    /// Parses the body that follows the session-id on the wire.
    /// Pass `hasPacketID: false` for P_ACK_V1, whose body is the ACK vector
    /// only. Returns nil on truncation.
    public static func parse(_ data: Data, hasPacketID: Bool = true) -> ControlPacketBody? {
        // Normalize slices: callers pass subdata with non-zero startIndex.
        let data = Data(data)
        var cursor = data.startIndex

        func take(_ count: Int) -> Data? {
            guard cursor + count <= data.endIndex else { return nil }
            defer { cursor += count }
            return data.subdata(in: cursor..<(cursor + count))
        }

        guard let countByte = take(1), let n = countByte.first else { return nil }
        var ackIDs: [UInt32] = []
        for _ in 0..<Int(n) {
            guard let pid = take(4), let value = try? UInt32(bigEndianData: pid) else { return nil }
            ackIDs.append(value)
        }
        let ackSID = n > 0 ? take(8) : nil
        guard hasPacketID else {
            return ControlPacketBody(
                ackPacketIDs: ackIDs,
                ackRemoteSessionID: ackSID,
                packetID: 0,
                payload: Data()
            )
        }
        guard let pidData = take(4), let pid = try? UInt32(bigEndianData: pidData) else { return nil }
        let payload = take(data.count - cursor) ?? Data()

        return ControlPacketBody(
            ackPacketIDs: ackIDs,
            ackRemoteSessionID: ackSID,
            packetID: pid,
            payload: payload
        )
    }
}

/// A P_DATA_V2 data-channel header.
///
/// The 4-byte header is `[opcode|keyid][peer-id (24 bits)]`. Everything after
/// it is produced/consumed by `DataChannelCrypto`.
public struct DataPacketHeader: Sendable, Equatable {
    public var keyID: UInt8
    public var peerID: UInt32   // 24 bits

    public init(keyID: UInt8, peerID: UInt32) {
        self.keyID = keyID
        self.peerID = peerID
    }

    public var encoded: Data {
        var bytes = Data()
        bytes.append(PacketHeader.encode(opcode: .dataV2, keyID: keyID))
        bytes.append(UInt8((peerID >> 16) & 0xFF))
        bytes.append(UInt8((peerID >> 8) & 0xFF))
        bytes.append(UInt8(peerID & 0xFF))
        return bytes
    }

    public static func parse(_ data: Data) -> DataPacketHeader? {
        guard data.count >= 4 else { return nil }
        let (opcode, keyID) = PacketHeader.decode(data[0])
        guard opcode == .dataV2 else { return nil }
        let peerID = (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3])
        return DataPacketHeader(keyID: keyID, peerID: peerID)
    }
}

public extension UInt16 {
    var bigEndianBytes: Data {
        var value = self.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

public extension UInt32 {
    var bigEndianBytes: Data {
        var value = self.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    init(bigEndianData data: Data) throws {
        guard data.count == 4 else { throw OpenVPNProtocolError.truncatedPacket }
        let loaded: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        self = UInt32(bigEndian: loaded)
    }
}
