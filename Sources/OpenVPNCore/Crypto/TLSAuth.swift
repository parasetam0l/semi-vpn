import Foundation
import CommonCrypto

public enum TLSAuthError: Error, Sendable, Equatable {
    case packetTooShort
    case badKey
    case hmacMismatch
}

/// `tls-auth` protection for the control channel (OpenVPN 2.7 semantics).
///
/// On-wire format:
///
///     [opcode(1)][sid(8)][hmac(n)][transport-pid(8)][acks][rel-pid(4)][payload]
///
/// The HMAC tag (digest size, from the profile's `auth` setting) covers the
/// *entire* packet from the opcode byte through the end of the payload
/// (everything except the tag itself) and is inserted after the session-id,
/// before the ACK vector. The transport packet-id is the long form
/// `[id(4)][time(4)]`, starting at id 1.
///
/// Directional keys (verified against OpenVPN 2.7 wire captures): a client
/// with `key-direction 1` signs outgoing packets with `keys[1]` of the
/// static key file and verifies incoming packets with `keys[0]`.
public struct TLSAuth: Sendable {
    public var digest: OVPNProfile.Digest
    public var sendKey: Data
    public var verifyKey: Data
    public var transportPID: UInt32
    public var transportTime: UInt32

    public init(digest: OVPNProfile.Digest = .sha256, sendKey: Data, verifyKey: Data) {
        self.digest = digest
        self.sendKey = sendKey
        self.verifyKey = verifyKey
        self.transportPID = 0
        self.transportTime = UInt32(Date().timeIntervalSince1970)
    }

    public var tagLength: Int {
        switch digest {
        case .sha1: return 20
        case .sha256: return 32
        case .sha384: return 48
        case .sha512: return 64
        }
    }

    /// Wraps a fully built control packet `[opcode][sid][acks][pid][payload]`
    /// into its on-wire `tls-auth` form, consuming the next transport-pid.
    ///
    /// The HMAC covers `[transport-pid][opcode][sid][acks][rel-pid][payload]`
    /// — the transport-pid is part of the authenticated data.
    public mutating func wrap(packet: Data) -> Data? {
        guard sendKey.count > 0 else { return nil }
        transportPID &+= 1
        var pid = Data()
        pid.append(transportPID.bigEndianBytes)
        pid.append(transportTime.bigEndianBytes)

        let tag = hmac(pid + packet, key: sendKey)

        var out = Data()
        out.append(packet.prefix(9))        // opcode + session-id
        out.append(tag)                     // hmac
        out.append(pid)                     // transport packet-id (id + time)
        out.append(packet.dropFirst(9))     // acks + rel-pid + payload
        return out
    }

    /// Verifies and unwraps an incoming `tls-auth` packet. Returns the
    /// plain control packet `[opcode][sid][acks][pid][payload]`, or nil
    /// when authentication fails.
    public func unwrap(_ packet: Data) -> Data? {
        let tagLen = tagLength
        guard packet.count >= 9 + tagLen + 8 else { return nil }
        let tag = packet.subdata(in: 9..<(9 + tagLen))
        let pid = packet.dropFirst(9 + tagLen).prefix(8)
        let expected = hmac(Data(pid) + Data(packet.prefix(9)) + packet.dropFirst(9 + tagLen + 8), key: verifyKey)
        guard constantTimeEquals(tag, expected) else { return nil }
        return Data(packet.prefix(9)) + packet.dropFirst(9 + tagLen + 8)
    }

    private func hmac(_ data: Data, key: Data) -> Data {
        var mac = [UInt8](repeating: 0, count: tagLength)
        let alg: CCHmacAlgorithm
        switch digest {
        case .sha1: alg = CCHmacAlgorithm(kCCHmacAlgSHA1)
        case .sha256: alg = CCHmacAlgorithm(kCCHmacAlgSHA256)
        case .sha384: alg = CCHmacAlgorithm(kCCHmacAlgSHA384)
        case .sha512: alg = CCHmacAlgorithm(kCCHmacAlgSHA512)
        }
        let keyBytes = [UInt8](key)
        let bodyBytes = [UInt8](data)
        keyBytes.withUnsafeBufferPointer { keyPtr in
            bodyBytes.withUnsafeBufferPointer { bodyPtr in
                CCHmac(
                    alg,
                    keyPtr.baseAddress, keyBytes.count,
                    bodyPtr.baseAddress, bodyBytes.count,
                    &mac
                )
            }
        }
        return Data(mac)
    }

    private func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        let ab = [UInt8](a)
        let bb = [UInt8](b)
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }
}
