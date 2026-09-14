import Foundation

public enum StaticKeyError: Error, Sendable, Equatable {
    case notStaticKeyPEM
    case malformedKeyData
}

/// OpenVPN static key file (`tls-auth` / `tls-crypt` keys), OpenVPN 2.7
/// format.
///
/// The decoded payload is 256 bytes: two 128-byte key sets of
/// `cipher[64] + hmac[64]`:
///
///     keys[0].cipher = bytes[0..64]     keys[0].hmac = bytes[64..128]
///     keys[1].cipher = bytes[128..192]  keys[1].hmac = bytes[192..256]
///
/// Directional mapping (OpenVPN 2.7 `key_direction_state_init`): a client
/// with `key-direction 1` (KEY_DIRECTION_NORMAL) signs outgoing packets with
/// `keys[1]` and verifies incoming packets with `keys[0]`; the server
/// mirrors this.
public struct OpenVPNStaticKey: Sendable, Equatable {
    public var cipherKey1: Data
    public var hmacKey1: Data
    public var cipherKey2: Data
    public var hmacKey2: Data

    public init(cipherKey1: Data, hmacKey1: Data, cipherKey2: Data, hmacKey2: Data) {
        self.cipherKey1 = cipherKey1
        self.hmacKey1 = hmacKey1
        self.cipherKey2 = cipherKey2
        self.hmacKey2 = hmacKey2
    }

    public static func parse(pem: String) throws -> OpenVPNStaticKey {
        var hexLines: [String] = []
        var inBody = false
        for line in pem.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-----BEGIN") {
                guard trimmed.contains("Static key") else {
                    throw StaticKeyError.notStaticKeyPEM
                }
                inBody = true
                continue
            }
            if trimmed.hasPrefix("-----END") {
                inBody = false
                continue
            }
            if inBody, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                hexLines.append(trimmed)
            }
        }

        let joined = hexLines.joined(separator: "")
        guard joined.count == 4 * 128 else {
            throw StaticKeyError.malformedKeyData
        }

        let bytes = hexToData(joined)
        guard bytes.count == 256 else {
            throw StaticKeyError.malformedKeyData
        }

        func slice(_ offset: Int, _ count: Int) -> Data {
            bytes.subdata(in: offset..<(offset + count))
        }

        return OpenVPNStaticKey(
            cipherKey1: slice(0, 64),
            hmacKey1: slice(64, 64),
            cipherKey2: slice(128, 64),
            hmacKey2: slice(192, 64)
        )
    }
}

private func hexToData(_ hex: String) -> Data {
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        guard let byte = UInt8(hex[index..<next], radix: 16) else { break }
        data.append(byte)
        index = next
    }
    return data
}
