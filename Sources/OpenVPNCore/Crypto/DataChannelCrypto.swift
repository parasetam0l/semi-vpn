import Foundation
import CommonCrypto
import CryptoKit

public enum DataChannelError: Error, Sendable, Equatable {
    case badPacket
    case hmacMismatch
    case decryptionFailed
    case unsupportedCipher
    case replayedPacket
}

/// Directional data-channel keys, derived from the key-expansion PRF output
/// (see `TLSKeyExpansion`). For AEAD ciphers the HMAC slot carries the
/// implicit-IV material instead of being used as a MAC.
public struct DataChannelKeySet: Sendable, Equatable {
    public var cipher: OVPNProfile.Cipher
    public var digest: OVPNProfile.Digest
    public var encryptKey: Data
    public var encryptHMAC: Data   // CBC: HMAC key; AEAD: implicit IV source
    public var decryptKey: Data
    public var decryptHMAC: Data

    public init(
        cipher: OVPNProfile.Cipher,
        digest: OVPNProfile.Digest,
        encryptKey: Data,
        encryptHMAC: Data,
        decryptKey: Data,
        decryptHMAC: Data
    ) {
        self.cipher = cipher
        self.digest = digest
        self.encryptKey = encryptKey
        self.encryptHMAC = encryptHMAC
        self.decryptKey = decryptKey
        self.decryptHMAC = decryptHMAC
    }
}

/// AEAD-epoch keys (OpenVPN 2.7 `crypto_epoch.c`): the per-epoch data key
/// and the 12-byte implicit IV, derived per direction via
/// `OVPN-Expand-Label`. The nonce XORs the implicit IV with the 8-byte
/// epoch packet-id; AAD covers the 4-byte header plus the packet-id.
public struct DataChannelEpochKeySet: Sendable, Equatable {
    public var cipher: OVPNProfile.Cipher
    public var sendKey: Data
    public var sendIV: Data
    public var recvKey: Data
    public var recvIV: Data

    public init(cipher: OVPNProfile.Cipher, sendKey: Data, sendIV: Data, recvKey: Data, recvIV: Data) {
        self.cipher = cipher
        self.sendKey = sendKey
        self.sendIV = sendIV
        self.recvKey = recvKey
        self.recvIV = recvIV
    }
}

/// Data-channel wire formatting, verified against OpenVPN 2.6
/// `crypto.c` / `forward.c`.
///
/// CBC mode — the header is *not* authenticated; a random 16-byte IV is
/// transmitted in clear; the 4-byte packet-id is encrypted inside the
/// plaintext; the HMAC covers the IV and the ciphertext:
///
///     [hdr(4)][hmac(n)][iv(16)][ciphertext(pid||payload, PKCS7)]
///
/// AEAD mode — the header and packet-id are authenticated data, the 16-byte
/// tag precedes the ciphertext, and the nonce is packet-id (4) plus an
/// 8-byte implicit IV copied from the direction's HMAC slot:
///
///     [hdr(4)][pid(4)][tag(16)][ciphertext]
///
/// Nonce = [pid || implicit-iv], AAD = [hdr || pid].
public struct DataChannelCrypto: Sendable {
    public var keys: DataChannelKeySet
    /// OpenVPN 2.7 AEAD-epoch data format (8-byte packet-id, XOR nonce,
    /// epoch keys) when the server pushed `protocol-flags aead-epoch`.
    public var epochKeys: DataChannelEpochKeySet?
    /// Sliding-window replay filter over received packet-ids. nil disables
    /// the check (not recommended outside of tests).
    public var replay: ReplayWindow?
    /// Whether the classic AEAD formats authenticate the wire header along
    /// with the packet-id (the 2.7 epoch format always does). OpenVPN
    /// builds differ for the classic formats, so receiving self-adjusts:
    /// a packet that only authenticates with pid-only AAD flips the mode
    /// for the rest of the session (both directions).
    public var classicAADIncludesHeader = true

    public init(
        keys: DataChannelKeySet,
        epochKeys: DataChannelEpochKeySet? = nil,
        replay: ReplayWindow? = ReplayWindow()
    ) {
        self.keys = keys
        self.epochKeys = epochKeys
        self.replay = replay
    }

    public var hmacLength: Int {
        keys.cipher.isAEAD ? 0 : digestLength(keys.digest)
    }

    /// True when packets are sent in the 2.7 AEAD-epoch format (48-bit
    /// counter); otherwise the classic 32-bit packet-id applies.
    public var usesEpoch: Bool {
        keys.cipher.isAEAD && epochKeys != nil
    }

    // MARK: - Encrypt (produces the full on-wire data packet)

    /// - Parameter packetID: the monotonically increasing send counter. In
    ///   epoch format the low 48 bits go on the wire; otherwise it must fit
    ///   in 32 bits (callers should not wrap: GCM nonces would repeat).
    /// - Parameter useV1Header: P_DATA_V1 (single opcode byte, no peer-id)
    ///   when the peer sends V1; P_DATA_V2 otherwise.
    public func encrypt(
        plaintext: Data,
        packetID: UInt64,
        peerID: UInt32,
        keyID: UInt8,
        useV1Header: Bool = false
    ) throws -> Data {
        let header = useV1Header
            ? Data([PacketHeader.encode(opcode: .dataV1, keyID: keyID)])
            : DataPacketHeader(keyID: keyID, peerID: peerID).encoded
        switch keys.cipher {
        case .aes128GCM, .aes256GCM, .chacha20Poly1305:
            if let epochKeys {
                return try encryptEpoch(plaintext: plaintext, packetID: packetID, header: header, epochKeys: epochKeys)
            }
            return try encryptAEAD(plaintext: plaintext, packetID: UInt32(truncatingIfNeeded: packetID), header: header)
        case .aes128CBC, .aes256CBC:
            return try encryptCBC(plaintext: plaintext, packetID: UInt32(truncatingIfNeeded: packetID), header: header)
        }
    }

    private func encryptCBC(plaintext: Data, packetID: UInt32, header: Data) throws -> Data {
        var iv = Data(count: 16)
        guard iv.withUnsafeMutableBytes({
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }) == errSecSuccess else {
            throw DataChannelError.badPacket
        }

        // The packet-id rides inside the encrypted plaintext; CommonCrypto
        // applies PKCS7 padding automatically (kCCOptionPKCS7Padding), as
        // OpenVPN's OpenSSL EVP path does.
        var toEncrypt = Data()
        toEncrypt.append(packetID.bigEndianBytes)
        toEncrypt.append(plaintext)
        let ciphertext = try cbcCrypt(operation: CCOperation(kCCEncrypt), key: keys.encryptKey, iv: iv, data: toEncrypt)

        var authenticated = iv
        authenticated.append(ciphertext)
        let tag = hmac(data: authenticated, key: keys.encryptHMAC, digest: keys.digest)

        var out = header
        out.append(tag)
        out.append(iv)
        out.append(ciphertext)
        return out
    }

    private func encryptAEAD(plaintext: Data, packetID: UInt32, header: Data) throws -> Data {
        let nonce = try gcmNonce(packetID: packetID, implicitIV: keys.encryptHMAC)
        let aad = classicAADIncludesHeader ? header + packetID.bigEndianBytes : packetID.bigEndianBytes
        let sealed = try aesGCMSeal(plaintext: plaintext, nonce: nonce, key: keys.encryptKey, aad: aad)

        var out = header
        out.append(packetID.bigEndianBytes)
        out.append(sealed.tag)
        out.append(sealed.ciphertext)
        return out
    }

    /// Epoch format: 8-byte packet-id (16-bit epoch + 48-bit counter),
    /// nonce = implicit IV XOR [pid(8) || zeros(4)], AAD = header + pid.
    private func encryptEpoch(plaintext: Data, packetID: UInt64, header: Data, epochKeys: DataChannelEpochKeySet) throws -> Data {
        let pid = Self.epochPacketID(epoch: 1, counter: packetID)
        let nonce = try Self.epochNonce(packetID: pid, implicitIV: epochKeys.sendIV)
        let aad = header + pid
        let sealed = try aesGCMSeal(plaintext: plaintext, nonce: nonce, key: epochKeys.sendKey, aad: aad)

        var out = header
        out.append(pid)
        // Epoch format: ciphertext first, tag at the end.
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// The on-wire epoch packet-id: the big-endian `(epoch << 48 | counter)`
    /// (matches the captured server packets: `00 01 00 00 00 00 00 01` for
    /// epoch 1, counter 1).
    static func epochPacketID(epoch: UInt16, counter: UInt64) -> Data {
        var value = ((UInt64(epoch) << 48) | (counter & 0x0000_FFFF_FFFF_FFFF)).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    static func epochNonce(packetID: Data, implicitIV: Data) throws -> Data {
        guard packetID.count == 8, implicitIV.count == 12 else { throw DataChannelError.badPacket }
        var nonce = Data(repeating: 0, count: 12)
        for i in 0..<12 {
            nonce[i] = implicitIV[i] ^ (i < 8 ? packetID[i] : 0)
        }
        return nonce
    }

    // MARK: - Decrypt (parses a full received P_DATA_V2 packet)

    /// Decrypts one received packet (P_DATA_V1 or P_DATA_V2) and applies
    /// the replay filter. The filter state only advances for packets that
    /// authenticate correctly; failed decryptions leave it untouched.
    public mutating func decrypt(_ packet: Data, keyID: UInt8) throws -> Data {
        let (opcode, _) = PacketHeader.decode(packet[packet.startIndex])
        let body: Data
        let header: Data
        switch opcode {
        case .dataV2:
            guard let parsed = DataPacketHeader.parse(packet) else { throw DataChannelError.badPacket }
            body = Data(packet.dropFirst(4))
            header = parsed.encoded
        case .dataV1:
            body = Data(packet.dropFirst(1))
            header = Data([packet[packet.startIndex]])
        default:
            throw DataChannelError.badPacket
        }
        switch keys.cipher {
        case .aes128GCM, .aes256GCM, .chacha20Poly1305:
            if let epochKeys {
                return try decryptEpoch(body: body, header: header, epochKeys: epochKeys)
            }
            return try decryptAEAD(body: body, header: header)
        case .aes128CBC, .aes256CBC:
            return try decryptCBC(body: body)
        }
    }

    private mutating func decryptEpoch(body: Data, header: Data, epochKeys: DataChannelEpochKeySet) throws -> Data {
        // Minimum: epoch packet-id (8) + tag (16); the GCM ciphertext may
        // be empty in principle (OpenVPN never sends empty data packets).
        guard body.count >= 8 + 16 else { throw DataChannelError.badPacket }
        let pid = body.prefix(8)
        // Epoch format: ciphertext first, tag at the end.
        let ciphertext = body.dropFirst(8).dropLast(16)
        let tag = body.suffix(16)

        let nonce = try Self.epochNonce(packetID: Data(pid), implicitIV: epochKeys.recvIV)
        let aad = header + pid
        guard let opened = try aesGCMOpen(ciphertext: Data(ciphertext), tag: Data(tag), nonce: nonce, key: epochKeys.recvKey, aad: aad) else {
            throw DataChannelError.decryptionFailed
        }
        // The low 48 bits of the epoch packet-id are the counter.
        let pidValue = pid.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        try acceptReplay(pidValue & 0x0000_FFFF_FFFF_FFFF)
        return opened
    }

    private mutating func decryptCBC(body: Data) throws -> Data {
        let hmacLen = hmacLength
        guard body.count >= hmacLen + 16 + 16 else { throw DataChannelError.badPacket }

        let tag = body.prefix(hmacLen)
        let iv = body.dropFirst(hmacLen).prefix(16)
        let ciphertext = body.dropFirst(hmacLen + 16)

        let expected = hmac(data: Data(iv + ciphertext), key: keys.decryptHMAC, digest: keys.digest)
        guard constantTimeEquals(Data(tag), expected) else { throw DataChannelError.hmacMismatch }

        let padded = try cbcCrypt(operation: CCOperation(kCCDecrypt), key: keys.decryptKey, iv: Data(iv), data: Data(ciphertext))
        // CommonCrypto already stripped the PKCS7 padding; the packet-id
        // rides inside the plaintext and is checked here (as OpenVPN does).
        guard padded.count >= 4 else { throw DataChannelError.badPacket }
        let pid = padded.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        try acceptReplay(pid)
        return padded.dropFirst(4)
    }

    private mutating func decryptAEAD(body: Data, header: Data) throws -> Data {
        // Minimum: packet-id (4) + tag (16); ciphertext >= plaintext length.
        guard body.count >= 4 + 16 else { throw DataChannelError.badPacket }
        let pidBytes = body.prefix(4)
        let pid = try UInt32(bigEndianData: Data(pidBytes))
        let tag = body.dropFirst(4).prefix(16)
        let ciphertext = body.dropFirst(4 + 16)

        let nonce = try gcmNonce(packetID: pid, implicitIV: keys.decryptHMAC)

        // The classic AEAD AAD ambiguity is resolved by trying both
        // constructions; the mode flips ONLY when a packet actually
        // authenticates under the other one (corrupt packets never flip).
        func open(aad: Data) throws -> Data? {
            try aesGCMOpen(
                ciphertext: Data(ciphertext), tag: Data(tag), nonce: nonce,
                key: keys.decryptKey, aad: aad
            )
        }
        if classicAADIncludesHeader {
            if let opened = try open(aad: header + Data(pidBytes)) {
                try acceptReplay(UInt64(pid))
                return opened
            }
            if let opened = try open(aad: Data(pidBytes)) {
                classicAADIncludesHeader = false
                try acceptReplay(UInt64(pid))
                return opened
            }
        } else {
            if let opened = try open(aad: Data(pidBytes)) {
                try acceptReplay(UInt64(pid))
                return opened
            }
            if let opened = try open(aad: header + Data(pidBytes)) {
                classicAADIncludesHeader = true
                try acceptReplay(UInt64(pid))
                return opened
            }
        }
        throw DataChannelError.decryptionFailed
    }

    private mutating func acceptReplay(_ packetID: UInt64) throws {
        guard var filter = replay else { return }
        guard filter.accept(packetID) else {
            throw DataChannelError.replayedPacket
        }
        replay = filter
    }

    // MARK: - Primitives

    private struct Sealed {
        var tag: Data
        var ciphertext: Data
    }

    private func aesGCMSeal(plaintext: Data, nonce: Data, key: Data, aad: Data) throws -> Sealed {
        switch keys.cipher {
        case .aes128GCM:
            let sym = SymmetricKey(data: key.prefix(16))
            let box = try AES.GCM.seal(plaintext, using: sym, nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad)
            return Sealed(tag: box.tag, ciphertext: box.ciphertext)
        case .aes256GCM:
            let sym = SymmetricKey(data: key)
            let box = try AES.GCM.seal(plaintext, using: sym, nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad)
            return Sealed(tag: box.tag, ciphertext: box.ciphertext)
        case .chacha20Poly1305:
            let sym = SymmetricKey(data: key)
            let box = try ChaChaPoly.seal(plaintext, using: sym, nonce: try ChaChaPoly.Nonce(data: nonce), authenticating: aad)
            return Sealed(tag: box.tag, ciphertext: box.ciphertext)
        default:
            throw DataChannelError.unsupportedCipher
        }
    }

    /// Returns nil when authentication or decryption fails; CryptoKit's
    /// error is normalized so callers see `DataChannelError` only.
    private func aesGCMOpen(ciphertext: Data, tag: Data, nonce: Data, key: Data, aad: Data) throws -> Data? {
        do {
            switch keys.cipher {
            case .aes128GCM:
                let sym = SymmetricKey(data: key.prefix(16))
                let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                return try AES.GCM.open(box, using: sym, authenticating: aad)
            case .aes256GCM:
                let sym = SymmetricKey(data: key)
                let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                return try AES.GCM.open(box, using: sym, authenticating: aad)
            case .chacha20Poly1305:
                let sym = SymmetricKey(data: key)
                let box = try ChaChaPoly.SealedBox(combined: nonce + ciphertext + tag)
                return try ChaChaPoly.open(box, using: sym, authenticating: aad)
            default:
                throw DataChannelError.unsupportedCipher
            }
        } catch {
            return nil
        }
    }

    private func gcmNonce(packetID: UInt32, implicitIV: Data) throws -> Data {
        var nonce = Data()
        nonce.append(packetID.bigEndianBytes)
        nonce.append(implicitIV.prefix(8))
        guard nonce.count == 12 else { throw DataChannelError.badPacket }
        return nonce
    }

    private func cbcCrypt(operation: CCOperation, key: Data, iv: Data, data: Data) throws -> Data {
        var outLen = 0
        var out = Data(count: data.count + 16)
        let outCapacity = out.count
        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        let dataBytes = [UInt8](data)
        let status = dataBytes.withUnsafeBufferPointer { dataPtr in
            keyBytes.withUnsafeBufferPointer { keyPtr in
                ivBytes.withUnsafeBufferPointer { ivPtr in
                    out.withUnsafeMutableBytes { outPtr in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyBytes.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, dataBytes.count,
                            outPtr.baseAddress, outCapacity,
                            &outLen
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DataChannelError.decryptionFailed }
        out.removeLast(out.count - outLen)
        return out
    }

    private func hmac(data: Data, key: Data, digest: OVPNProfile.Digest) -> Data {
        let len = digestLength(digest)
        var mac = [UInt8](repeating: 0, count: len)
        let alg: CCHmacAlgorithm
        switch digest {
        case .sha1: alg = CCHmacAlgorithm(kCCHmacAlgSHA1)
        case .sha256: alg = CCHmacAlgorithm(kCCHmacAlgSHA256)
        case .sha384: alg = CCHmacAlgorithm(kCCHmacAlgSHA384)
        case .sha512: alg = CCHmacAlgorithm(kCCHmacAlgSHA512)
        }
        let keyBytes = [UInt8](key)
        let dataBytes = [UInt8](data)
        keyBytes.withUnsafeBufferPointer { k in
            dataBytes.withUnsafeBufferPointer { body in
                CCHmac(alg, k.baseAddress, key.count, body.baseAddress, body.count, &mac)
            }
        }
        return Data(mac)
    }

    func digestLength(_ digest: OVPNProfile.Digest) -> Int {
        switch digest {
        case .sha1: return 20
        case .sha256: return 32
        case .sha384: return 48
        case .sha512: return 64
        }
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
