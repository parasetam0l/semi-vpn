import Foundation
import CommonCrypto

func hmacSHA256(key: Data, data: Data) -> Data? {
    var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    key.withUnsafeBytes { keyBytes in
        data.withUnsafeBytes { dataBytes in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes.baseAddress, key.count,
                   dataBytes.baseAddress, data.count, &mac)
        }
    }
    return Data(mac)
}

public enum KeyExpansionError: Error, Sendable, Equatable {
    case badSecretLength
    case badMessageFormat
    case keyExportUnavailable
}

/// OpenVPN's TLS-1.0-style PRF, used for data-channel key derivation.
///
/// Verified against OpenVPN 2.6 `crypto_openssl.c` / `ssl.c`:
///
///     PRF(secret, label, client_seed, server_seed, client_sid, server_sid)
///       = P_MD5(S1, seed) XOR P_SHA1(S2, seed)
///
/// where `seed` = label || client_seed || server_seed || client_sid || server_sid,
/// S1 is the first half of the secret, S2 the second, and P_hash is the
/// HMAC-based expansion from RFC 5246.
public enum OpenVPNPRF {
    public static func derive(
        secret: Data,
        label: String,
        clientSeed: Data,
        serverSeed: Data,
        clientSessionID: Data? = nil,
        serverSessionID: Data? = nil,
        outputLength: Int
    ) -> Data? {
        guard secret.count == 48 else { return nil }

        var seed = Data(label.utf8)
        seed.append(clientSeed)
        seed.append(serverSeed)
        if let clientSessionID { seed.append(clientSessionID) }
        if let serverSessionID { seed.append(serverSessionID) }

        let s1 = secret.prefix(24)
        let s2 = secret.dropFirst(24)

        guard let p1 = pHash(md: .md5, secret: Data(s1), seed: seed, length: outputLength),
              let p2 = pHash(md: .sha1, secret: Data(s2), seed: seed, length: outputLength) else {
            return nil
        }

        return Data(zip(p1, p2).map { $0 ^ $1 })
    }

    enum HashAlg {
        case md5
        case sha1
    }

    static func pHash(md: HashAlg, secret: Data, seed: Data, length: Int) -> Data? {
        let digestLen: Int
        let alg: CCHmacAlgorithm
        switch md {
        case .md5:
            digestLen = Int(CC_MD5_DIGEST_LENGTH)
            alg = CCHmacAlgorithm(kCCHmacAlgMD5)
        case .sha1:
            digestLen = Int(CC_SHA1_DIGEST_LENGTH)
            alg = CCHmacAlgorithm(kCCHmacAlgSHA1)
        }

        func hmac(_ data: Data) -> Data {
            var mac = [UInt8](repeating: 0, count: digestLen)
            data.withUnsafeBytes { body in
                secret.withUnsafeBytes { key in
                    CCHmac(alg, key.baseAddress, secret.count, body.baseAddress, body.count, &mac)
                }
            }
            return Data(mac)
        }

        var a = hmac(seed)
        var out = Data()
        while out.count < length {
            var block = hmac(a + seed)
            out.append(block)
            a = hmac(a)
            block.removeAll()
        }
        return out.prefix(length)
    }
}

/// Parses and builds `key_method_2` control-channel messages, and maps the
/// key-expansion output onto directional key material.
///
/// Client message (OpenVPN 2.6/2.7 `key_method_2_write`):
///
///     [u32 0][u8 2][pre_master 48][random1 32][random2 32]
///     [u16 len][options\0][u16 len][user\0][u16 len][pass\0][u16 len][peer_info\0]
///
/// where strings are **u16 length-prefixed** (the length includes the
/// trailing NUL) — not bare null-terminated strings. Empty username/password
/// strings are `[u16 1][\0]`.
///
/// Server message: `[u32 0][u8 2][random1 32][random2 32]` followed by the
/// same length-prefixed strings (empty credentials and peer info).
public struct KeyMethod2 {
    public static let preMasterLength = 48
    public static let randomLength = 32

    public struct ClientMaterial: Sendable, Equatable {
        public var preMaster: Data
        public var random1: Data
        public var random2: Data
        public var options: String
        public var username: String?
        public var password: String?
        public var peerInfo: String

        public init(preMaster: Data, random1: Data, random2: Data, options: String, username: String? = nil, password: String? = nil, peerInfo: String = "") {
            self.preMaster = preMaster
            self.random1 = random1
            self.random2 = random2
            self.options = options
            self.username = username
            self.password = password
            self.peerInfo = peerInfo
        }
    }

    public struct ServerMaterial: Sendable, Equatable {
        public var random1: Data
        public var random2: Data
        public var options: String

        public init(random1: Data, random2: Data, options: String) {
            self.random1 = random1
            self.random2 = random2
            self.options = options
        }
    }

    public static func makeClientMaterial(options: String, username: String? = nil, password: String? = nil, peerInfo: String = "") -> ClientMaterial {
        ClientMaterial(
            preMaster: randomBytes(48),
            random1: randomBytes(32),
            random2: randomBytes(32),
            options: options,
            username: username,
            password: password,
            peerInfo: peerInfo
        )
    }

    /// Encodes a string as `[u16 length][bytes][\0]` (length includes the NUL).
    static func lengthPrefixed(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        var out = Data()
        out.append(UInt8(UInt16(bytes.count + 1) >> 8))
        out.append(UInt8(UInt16(bytes.count + 1) & 0xFF))
        out.append(bytes)
        out.append(0)
        return out
    }

    public static func encode(client material: ClientMaterial) -> Data {
        var out = Data()
        out.append(contentsOf: [0, 0, 0, 0])          // u32 0
        out.append(2)                                  // key method 2
        out.append(material.preMaster)
        out.append(material.random1)
        out.append(material.random2)
        out.append(lengthPrefixed(material.options))
        out.append(lengthPrefixed(material.username ?? ""))
        out.append(lengthPrefixed(material.password ?? ""))
        out.append(lengthPrefixed(material.peerInfo))
        return out
    }

    /// Parses the server's key_method_2 message.
    public static func parse(server data: Data) -> ServerMaterial? {
        var cursor = 0
        func take(_ count: Int) -> Data? {
            guard cursor + count <= data.count else { return nil }
            defer { cursor += count }
            return data.subdata(in: cursor..<(cursor + count))
        }
        guard let zero = take(4), zero == Data([0, 0, 0, 0]) else { return nil }
        guard let method = take(1), method == Data([2]) else { return nil }
        guard let random1 = take(randomLength), let random2 = take(randomLength) else { return nil }

        // Length-prefixed options string ([u16 len][bytes\0]).
        guard let lenBytes = take(2) else { return nil }
        let strLen = UInt32(lenBytes[0]) << 8 | UInt32(lenBytes[1])
        guard strLen >= 1, strLen <= 512 else { return nil }
        guard let raw = take(Int(strLen)), raw.last == 0 else { return nil }
        let options = String(data: raw.dropLast(), encoding: .utf8) ?? ""

        return ServerMaterial(random1: random1, random2: random2, options: options)
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes {
            _ = SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        return bytes
    }
}

/// The full 192-byte key expansion for both directions, mapped onto the
/// OpenVPN `key2` layout: two `struct key` of `cipher[32] + hmac[64]`.
public struct KeyExpansion {
    /// OpenVPN 2.7 key material: two `struct key` entries of
    /// cipher[64] + hmac[64] each.
    public static let keyMaterialLength = 2 * (64 + 64)

    /// Classic OpenVPN PRF derivation (used unless the server pushes
    /// `key-derivation tls-ekm`).
    public static func derivePRF(
        client: KeyMethod2.ClientMaterial,
        server: KeyMethod2.ServerMaterial,
        clientSessionID: Data,
        serverSessionID: Data
    ) -> Data? {
        guard let master = OpenVPNPRF.derive(
            secret: client.preMaster,
            label: "OpenVPN master secret",
            clientSeed: client.random1,
            serverSeed: server.random1,
            outputLength: 48
        ) else { return nil }

        return OpenVPNPRF.derive(
            secret: master,
            label: "OpenVPN key expansion",
            clientSeed: client.random2,
            serverSeed: server.random2,
            clientSessionID: clientSessionID,
            serverSessionID: serverSessionID,
            outputLength: keyMaterialLength
        )
    }

    /// RFC 5705 exporter derivation (label `EXPORTER-OpenVPN-datakeys`).
    public static func deriveExporter(tls: TLSEngine) throws -> Data {
        guard let material = tls.exportKeyMaterial(label: "EXPORTER-OpenVPN-datakeys", length: keyMaterialLength) else {
            throw KeyExpansionError.keyExportUnavailable
        }
        return material
    }

    /// Maps key material onto directional key sets for a client.
    ///
    /// The layout depends on the expansion length:
    /// - 256 bytes (RFC 5705 exporter, OpenVPN 2.6/2.7): keys[0] =
    ///   material[0..128] (cipher slot 0..64, hmac slot 64..128), keys[1] =
    ///   material[128..256].
    /// - 192 bytes (classic OpenVPN PRF, OpenVPN 2.4-era): keys[0] =
    ///   material[0..96] (cipher 0..32, hmac 32..96), keys[1] = [96..192].
    ///
    /// The client (KEY_DIRECTION_NORMAL) encrypts with keys[0] and decrypts
    /// with keys[1].
    public static func keySet(material: Data, cipher: OVPNProfile.Cipher, digest: OVPNProfile.Digest) -> DataChannelKeySet? {
        let keyLen = cipherKeyLength(cipher)
        let hmacLen = hmacKeyLength(cipher, digest)

        let slotSize: Int
        let hmacOffset: Int
        switch material.count {
        case 256:
            slotSize = 128
            hmacOffset = 64
        case 192:
            slotSize = 96
            hmacOffset = 32
        default:
            return nil
        }

        func keySlice(_ slot: Int) -> Data {
            material.subdata(in: slot * slotSize..<(slot * slotSize + keyLen))
        }
        func hmacSlice(_ slot: Int) -> Data {
            material.subdata(in: slot * slotSize + hmacOffset..<(slot * slotSize + hmacOffset + hmacLen))
        }

        return DataChannelKeySet(
            cipher: cipher,
            digest: digest,
            encryptKey: keySlice(0),
            encryptHMAC: hmacSlice(0),
            decryptKey: keySlice(1),
            decryptHMAC: hmacSlice(1)
        )
    }

    /// AEAD-epoch data channel keys (OpenVPN 2.7 `crypto_epoch.c`).
    ///
    /// Epoch 1 derives from the first 32 bytes of each direction's classic
    /// cipher key; the per-epoch data key and implicit IV come from
    /// `OVPN-Expand-Label` (HKDF-Expand-Label with the "ovpn " label prefix):
    ///
    ///     K  = OVPN-Expand-Label(E1, "data_key", "", key_size)
    ///     IV = OVPN-Expand-Label(E1, "data_iv", "", 12)
    ///
    /// The wire packet-id is 8 bytes: 16-bit epoch + 48-bit per-epoch
    /// counter; the AEAD nonce XORs the implicit IV with the packet-id.
    public static func epochKeySet(material: Data, cipher: OVPNProfile.Cipher) -> DataChannelEpochKeySet? {
        // E1 secrets are the first 32 bytes of each direction's cipher key
        // from the classic key2 layout: each key occupies 128 bytes
        // (cipher[64] + hmac[64]), the client encrypts with keys[0]
        // (material[0:32]) and decrypts with keys[1] (material[slot:slot+32]).
        let slotSize = material.count / 2
        guard material.count == 256 || material.count == 192, slotSize >= 32 else { return nil }
        let sendSecret = material.subdata(in: 0..<32)
        let recvSecret = material.subdata(in: slotSize..<(slotSize + 32))
        let keySize = cipherKeyLength(cipher)
        guard let sendKey = expandLabel(secret: sendSecret, label: "data_key", length: keySize),
              let sendIV = expandLabel(secret: sendSecret, label: "data_iv", length: 12),
              let recvKey = expandLabel(secret: recvSecret, label: "data_key", length: keySize),
              let recvIV = expandLabel(secret: recvSecret, label: "data_iv", length: 12) else {
            return nil
        }
        return DataChannelEpochKeySet(
            cipher: cipher,
            sendKey: sendKey,
            sendIV: sendIV,
            recvKey: recvKey,
            recvIV: recvIV
        )
    }

    /// `OVPN-Expand-Label(secret, label, "", length)` from `crypto_epoch.c`:
    /// the RFC 8446 HKDF-Expand-Label with the "ovpn " label prefix and no
    /// context, i.e. `HKDF-Expand(SHA-256, secret, label || 0x01)`.
    static func expandLabel(secret: Data, label: String, length: Int) -> Data? {
        let prefix = Data("ovpn ".utf8)
        let labelBytes = Data(label.utf8)
        var info = Data()
        info.append(UInt16(length).bigEndianBytes)
        info.append(UInt8(prefix.count + labelBytes.count))
        info.append(prefix)
        info.append(labelBytes)
        info.append(UInt8(0)) // empty context

        var input = info
        input.append(UInt8(1))
        guard let digest = hmacSHA256(key: secret, data: input) else { return nil }
        return digest.prefix(length)
    }

    static func cipherKeyLength(_ cipher: OVPNProfile.Cipher) -> Int {
        switch cipher {
        case .aes128CBC, .aes128GCM: return 16
        case .aes256CBC, .aes256GCM, .chacha20Poly1305: return 32
        }
    }

    static func hmacKeyLength(_ cipher: OVPNProfile.Cipher, _ digest: OVPNProfile.Digest) -> Int {
        if cipher.isAEAD { return 8 }
        switch digest {
        case .sha1: return 20
        case .sha256: return 32
        case .sha384: return 48
        case .sha512: return 64
        }
    }
}
