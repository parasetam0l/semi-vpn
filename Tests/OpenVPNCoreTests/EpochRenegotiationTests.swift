import Testing
import Foundation
@testable import OpenVPNCore

/// A client/server pair of data-channel crypto objects with mirrored keys.
private func epochPair(cipher: OVPNProfile.Cipher = .aes256GCM) throws -> (DataChannelCrypto, DataChannelCrypto) {
    let material = Data((0..<256).map { UInt8($0 & 0xFF) })
    let clientKeys = try #require(KeyExpansion.keySet(material: material, cipher: cipher, digest: .sha256))
    let clientEpoch = try #require(KeyExpansion.epochKeySet(material: material, cipher: cipher))
    let serverKeys = DataChannelKeySet(
        cipher: cipher, digest: .sha256,
        encryptKey: clientKeys.decryptKey, encryptHMAC: clientKeys.decryptHMAC,
        decryptKey: clientKeys.encryptKey, decryptHMAC: clientKeys.encryptHMAC
    )
    let serverEpoch = DataChannelEpochKeySet(
        cipher: cipher,
        sendKey: clientEpoch.recvKey, sendIV: clientEpoch.recvIV,
        recvKey: clientEpoch.sendKey, recvIV: clientEpoch.sendIV,
        sendSecret: clientEpoch.recvSecret, recvSecret: clientEpoch.sendSecret
    )
    return (DataChannelCrypto(keys: clientKeys, epochKeys: clientEpoch),
            DataChannelCrypto(keys: serverKeys, epochKeys: serverEpoch))
}

@Test("a peer's newer epoch is adopted, and the old key keeps decrypting in-flight packets")
func testEpochAdoption() throws {
    var (client, server) = try epochPair()
    let early = try server.encryptNext(plaintext: Data("old".utf8), peerID: 0, keyID: 0)
    #expect(try client.decrypt(try server.encryptNext(plaintext: Data("one".utf8), peerID: 0, keyID: 0), keyID: 0) == Data("one".utf8))

    // The server moves to epoch 2 (as it does at its AEAD usage limit).
    server.iterateSendEpoch()
    #expect(server.epochKeys?.sendEpoch == 2)
    #expect(server.sendPacketID == 0)
    let newer = try server.encryptNext(plaintext: Data("two".utf8), peerID: 0, keyID: 0)
    #expect(newer[4...5] == Data([0x00, 0x02]))   // epoch in the packet-id
    #expect(try client.decrypt(newer, keyID: 0) == Data("two".utf8))
    #expect(client.epochKeys?.recvEpoch == 2)
    // The client never sends on an older epoch than the peer uses.
    #expect(client.epochKeys?.sendEpoch == 2)
    #expect(try server.decrypt(try client.encryptNext(plaintext: Data("ack".utf8), peerID: 0, keyID: 0), keyID: 0) == Data("ack".utf8))

    // A packet still in flight from epoch 1 decrypts with the retiring key,
    // once.
    #expect(try client.decrypt(early, keyID: 0) == Data("old".utf8))
    #expect(throws: DataChannelError.replayedPacket) { try client.decrypt(early, keyID: 0) }
}

@Test("epochs beyond the future-key window are rejected")
func testEpochWindow() throws {
    var (client, server) = try epochPair()
    for _ in 0..<5 { server.iterateSendEpoch() }   // epoch 6 = current + 5
    let tooFar = try server.encryptNext(plaintext: Data("x".utf8), peerID: 0, keyID: 0)
    #expect(throws: DataChannelError.decryptionFailed) { try client.decrypt(tooFar, keyID: 0) }

    var (client2, server2) = try epochPair()
    for _ in 0..<4 { server2.iterateSendEpoch() }  // epoch 5 = current + 4
    let edge = try server2.encryptNext(plaintext: Data("y".utf8), peerID: 0, keyID: 0)
    #expect(try client2.decrypt(edge, keyID: 0) == Data("y".utf8))
}

@Test("the AEAD usage limit advances the send epoch")
func testEpochUsageLimit() throws {
    var (client, server) = try epochPair()
    client.usageLimit = 10
    for index in 0..<8 {
        let packet = try client.encryptNext(plaintext: Data(repeating: UInt8(index), count: 32), peerID: 0, keyID: 0)
        #expect(try server.decrypt(packet, keyID: 0).count == 32)
    }
    #expect((client.epochKeys?.sendEpoch ?? 0) >= 2)
    #expect(server.epochKeys?.recvEpoch == client.epochKeys?.sendEpoch)
    #expect(!client.needsRenegotiation)
}

@Test("classic keys ask for renegotiation before the packet-id wraps")
func testClassicRenegotiationTriggers() throws {
    var (client, _) = try epochPair()
    client.epochKeys = nil
    client.setSendPacketIDForTesting(DataChannelCrypto.packetIDWrapTrigger - 2)
    _ = try client.encryptNext(plaintext: Data("a".utf8), peerID: 0, keyID: 0)
    #expect(!client.needsRenegotiation)
    _ = try client.encryptNext(plaintext: Data("b".utf8), peerID: 0, keyID: 0)
    #expect(client.needsRenegotiation)

    client.setSendPacketIDForTesting(UInt64(UInt32.max))
    #expect(throws: DataChannelError.packetIDExhausted) {
        try client.encryptNext(plaintext: Data("c".utf8), peerID: 0, keyID: 0)
    }
}

@Test("data packets carry the key-id of the key that encrypted them")
func testKeyIDInHeader() throws {
    var (client, server) = try epochPair()
    let packet = try client.encryptNext(plaintext: Data("k".utf8), peerID: 5, keyID: 3)
    #expect(packet[0] & 0x07 == 3)
    #expect(try server.decrypt(packet, keyID: 3) == Data("k".utf8))
}

@Test("dynamic tls-crypt keys XOR the original key and use the client direction")
func testDynamicTlsCrypt() throws {
    let exported = Data(repeating: 0xAA, count: 256)
    let original = Data((0..<256).map { UInt8($0) })
    let wrapper = ControlWrapper(originalKeyMaterial: original)
    wrapper.enableDynamicTlsCrypt(exportedKey: exported)
    let crypt = try #require(wrapper.renegotiationCrypt)
    let expected = Data(zip(exported, original).map { $0 ^ $1 })
    #expect(crypt.clientKey.kc == expected)
    #expect(crypt.packetID == 0)
    #expect(!crypt.isV2)
}
