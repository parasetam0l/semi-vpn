import Foundation
import CommonCrypto

public enum TlsCryptError: Error, Sendable, Equatable {
    case badKeyFile
    case packetTooShort
    case hmacMismatch
    case unsupportedCipher
}

/// `tls-crypt` / `tls-crypt-v2` control-channel wrapping.
///
/// Verified byte-for-byte against OpenVPN 2.7.6 wire captures:
///
///     [pid: id(4)][time(4)][tag(32)][AES-256-CTR ciphertext]
///
/// - `tag`  = HMAC-SHA256([opcode || sid || pid] || plaintext), 32 bytes
/// - `IV`   = the first 16 bytes of the tag
/// - `ct`   = AES-256-CTR(plaintext), key = the direction's cipher key
/// - plaintext = [ack-count][acks][rel-pid][payload]
///
/// The client key file (`<tls-crypt-v2>` PEM block) contains 256 bytes of
/// key material followed by the 299-byte wrapped client key (WKc), which the
/// client transmits verbatim in its hard-reset V3 packet. The session's
/// wrap packet-id starts at `EARLY_NEG_START + 1` (0x0f000001) to announce
/// early-negotiation support.
public struct TlsCrypt: Sendable {
    public static let tagLength = 32
    public static let pidLength = 8
    public static let earlyNegStart: UInt32 = 0x0f00_0000
    public static let blockSize = 16
    public static let keyMaterialLength = 256

    /// Client key layout (OpenVPN 2.7 `struct key` = cipher[64] + hmac[64],
    /// key2 = 2 × 128 bytes).
    public struct ClientKey: Sendable {
        public var kc: Data          // 256 bytes of key material
        public var wkc: Data         // wrapped client key, transmitted verbatim

        public static let keyMaterialLength = 256

        public init(kc: Data, wkc: Data) {
            self.kc = kc
            self.wkc = wkc
        }

        /// Parses the raw decoded `<tls-crypt-v2>` PEM payload.
        public static func parse(decoded: Data) -> ClientKey? {
            guard decoded.count >= Self.keyMaterialLength else { return nil }
            return ClientKey(
                kc: decoded.prefix(Self.keyMaterialLength),
                wkc: decoded.dropFirst(Self.keyMaterialLength)
            )
        }

        /// Client (KEY_DIRECTION_INVERSE): encrypt = keys[1].
        /// cipher key = first 32 bytes of the keys[1] cipher slot (kc[128..192]);
        /// hmac key  = first 32 bytes of the keys[1] hmac slot (kc[192..256]).
        public var encryptCipherKey: Data { kc.subdata(in: 128..<160) }
        public var encryptHMACKey: Data { kc.subdata(in: 192..<224) }

        /// Server side (KEY_DIRECTION_NORMAL): encrypt = keys[0].
        public var decryptCipherKey: Data { kc.subdata(in: 0..<32) }
        public var decryptHMACKey: Data { kc.subdata(in: 64..<96) }
    }

    public var clientKey: ClientKey
    public var packetID: UInt32
    public var packetTime: UInt32

    public init(clientKey: ClientKey) {
        self.clientKey = clientKey
        self.packetID = TlsCrypt.earlyNegStart
        self.packetTime = UInt32(Date().timeIntervalSince1970)
    }

    /// Wraps a control-packet body (the reliable layer's
    /// `[acks][relpid][payload]`). Returns the `[pid][tag][ct]` portion that
    /// follows `[opcode][sid]` on the wire.
    ///
    /// `header` is the `[opcode(1)][sid(8)]` prefix; it is included in the
    /// HMAC input, as OpenVPN authenticates the full packet.
    public mutating func wrap(header: Data, body: Data) throws -> Data {
        packetID &+= 1
        var pid = Data()
        pid.append(packetID.bigEndianBytes)
        pid.append(packetTime.bigEndianBytes)

        let tag = hmac(header + pid + body, key: clientKey.encryptHMACKey)
        let ct = try aesCTR(data: body, key: clientKey.encryptCipherKey, iv: tag.prefix(16))

        var out = pid
        out.append(tag)
        out.append(ct)
        return out
    }

    /// Verifies and unwraps an incoming `tls-crypt` packet. Expects the wire
    /// bytes after `[opcode][sid]` and the 9-byte `header` for HMAC input.
    /// Returns the plaintext body.
    public func unwrap(header: Data, data: Data) throws -> Data {
        guard data.count >= Self.pidLength + Self.tagLength else {
            throw TlsCryptError.packetTooShort
        }
        let pid = data.prefix(Self.pidLength)
        let tag = data.dropFirst(Self.pidLength).prefix(Self.tagLength)
        let ct = data.dropFirst(Self.pidLength + Self.tagLength)

        let body = try aesCTR(data: Data(ct), key: clientKey.decryptCipherKey, iv: Data(tag.prefix(16)))

        let expected = hmac(header + Data(pid) + body, key: clientKey.decryptHMACKey)
        guard constantTimeEquals(Data(tag), expected) else {
            throw TlsCryptError.hmacMismatch
        }
        return body
    }

    private func hmac(_ data: Data, key: Data) -> Data {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let keyBytes = [UInt8](key)
        let bodyBytes = [UInt8](data)
        keyBytes.withUnsafeBufferPointer { keyPtr in
            bodyBytes.withUnsafeBufferPointer { bodyPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyPtr.baseAddress, keyBytes.count,
                    bodyPtr.baseAddress, bodyBytes.count,
                    &mac
                )
            }
        }
        return Data(mac)
    }

    private func aesCTR(data: Data, key: Data, iv: Data) throws -> Data {
        // CCCrypt (one-shot) does not support CTR; use the mode-based API.
        var cryptor: CCCryptorRef?
        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        let status = keyBytes.withUnsafeBufferPointer { keyPtr in
            ivBytes.withUnsafeBufferPointer { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivPtr.baseAddress,
                    keyPtr.baseAddress, keyBytes.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else {
            throw TlsCryptError.unsupportedCipher
        }
        defer { CCCryptorRelease(cryptor) }

        var out = Data(count: data.count + 16)
        let outCapacity = out.count
        var outLen = 0
        let dataBytes = [UInt8](data)
        let writeStatus = dataBytes.withUnsafeBufferPointer { dataPtr in
            out.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(cryptor, dataPtr.baseAddress, dataBytes.count, outPtr.baseAddress, outCapacity, &outLen)
            }
        }
        guard writeStatus == kCCSuccess else { throw TlsCryptError.unsupportedCipher }
        var finalLen = 0
        let finalStatus = out.withUnsafeMutableBytes { outPtr in
            CCCryptorFinal(cryptor, outPtr.baseAddress!.advanced(by: outLen), outCapacity - outLen, &finalLen)
        }
        guard finalStatus == kCCSuccess else { throw TlsCryptError.unsupportedCipher }
        out.removeLast(out.count - outLen - finalLen)
        return out
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
