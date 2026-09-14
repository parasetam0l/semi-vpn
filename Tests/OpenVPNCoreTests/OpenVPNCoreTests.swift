import Testing
import Foundation
@testable import OpenVPNCore

// MARK: - .ovpn parser

@Test("parses directives and inline blocks")
func testProfileParsing() throws {
    let text = """
    client
    dev tun
    proto udp
    remote 198.51.100.1 1194
    resolv-retry infinite
    nobind
    persist-key
    persist-tun
    remote-cert-tls server
    auth SHA512
    cipher AES-256-CBC
    verb 3
    <ca>
    -----BEGIN CERTIFICATE-----
    MIIBszCCAVmgAwIBAgIJAPexample
    -----END CERTIFICATE-----
    </ca>
    <cert>
    -----BEGIN CERTIFICATE-----
    MIIBszCCAVmgAwIBAgIJAPcert
    -----END CERTIFICATE-----
    </cert>
    <key>
    -----BEGIN PRIVATE KEY-----
    MIIBszCCAVmgAwIBAgIJAPkey
    -----END PRIVATE KEY-----
    </key>
    <tls-auth>
    -----BEGIN OpenVPN Static key V1-----
    abc
    -----END OpenVPN Static key V1-----
    </tls-auth>
    key-direction 1
    """
    let profile = try OVPNParser().parse(text)

    #expect(profile.transport == .udp)
    #expect(profile.remotes == [OVPNProfile.Remote(host: "198.51.100.1", port: 1194)])
    #expect(profile.cipher == .aes256CBC)
    #expect(profile.digest == .sha512)
    #expect(profile.device == .tun)
    #expect(profile.nobind)
    #expect(profile.persistKey)
    #expect(profile.persistTun)
    #expect(profile.remoteCertTLS == .server)
    #expect(profile.verbosity == 3)
    #expect(profile.caPEM?.contains("CERTIFICATE") == true)
    #expect(profile.certPEM != nil)
    #expect(profile.keyPEM != nil)
    #expect(profile.tlsAuthPEM != nil)
    #expect(profile.tlsAuthKey == nil)  // not valid base64
    #expect(profile.keyDirection == 1)
    #expect(!profile.rawDirectives.isEmpty)
}

@Test("parses quoted and comment lines")
func testQuotedAndComments() throws {
    let text = """
    # comment
    ; also comment
    remote "vpn.example.com" 443
    proto tcp
    """
    let profile = try OVPNParser().parse(text)
    #expect(profile.remotes == [OVPNProfile.Remote(host: "vpn.example.com", port: 443)])
    #expect(profile.transport == .tcp)
}

// MARK: - Packet framing

@Test("control body round-trip with acks")
func testControlBodyRoundTrip() throws {
    let body = ControlPacketBody(
        ackPacketIDs: [7, 8],
        ackRemoteSessionID: Data(repeating: 0xAB, count: 8),
        packetID: 42,
        payload: Data([1, 2, 3])
    )
    let parsed = ControlPacketBody.parse(body.encoded)
    #expect(parsed != nil)
    #expect(parsed?.ackPacketIDs == [7, 8])
    #expect(parsed?.ackRemoteSessionID == Data(repeating: 0xAB, count: 8))
    #expect(parsed?.packetID == 42)
    #expect(parsed?.payload == Data([1, 2, 3]))
}

@Test("P_ACK body has no packet-id field")
func testAckOnlyBody() throws {
    let body = ControlPacketBody(
        ackPacketIDs: [5],
        ackRemoteSessionID: Data(repeating: 0x11, count: 8),
        packetID: 0,
        payload: Data()
    ).encodedAcksOnly
    #expect(body.count == 1 + 4 + 8)

    let parsed = ControlPacketBody.parse(body, hasPacketID: false)
    #expect(parsed?.ackPacketIDs == [5])
    #expect(parsed?.payload.isEmpty == true)
}

@Test("data header encoding")
func testDataHeader() throws {
    let header = DataPacketHeader(keyID: 3, peerID: 0x12_34_56)
    let parsed = DataPacketHeader.parse(header.encoded)
    #expect(parsed?.keyID == 3)
    #expect(parsed?.peerID == 0x12_34_56)
    // opcode must be P_DATA_V2 = 9
    let (opcode, _) = PacketHeader.decode(header.encoded[0])
    #expect(opcode == .dataV2)
}

// MARK: - tls-auth

@Test("tls-auth wrap and unwrap round-trip")
func testTLSAuthRoundTrip() throws {
    let key = Data(repeating: 0x01, count: 32)
    var auth = TLSAuth(sendKey: key, verifyKey: key)

    var packet = Data()
    packet.append(PacketHeader.encode(opcode: .controlV1, keyID: 0))
    packet.append(Data(repeating: 0x55, count: 8))     // sid
    packet.append(Data([0]))                            // ack count
    packet.append(UInt32(10).bigEndianBytes)            // pid
    packet.append(Data("hello".utf8))

    guard let wrapped = auth.wrap(packet: packet) else {
        Issue.record("wrap failed")
        return
    }
    // layout: [opcode 1][sid 8][hmac 32][transport-pid 8 (id+time)][body...]
    #expect(wrapped.count == packet.count + 32 + 8)
    #expect(auth.transportPID == 1)

    guard let unwrapped = auth.unwrap(wrapped) else {
        Issue.record("unwrap failed")
        return
    }
    #expect(unwrapped == packet)
}

@Test("tls-auth rejects tampered packets")
func testTLSAuthTamper() throws {
    var auth = TLSAuth(sendKey: Data(repeating: 0x01, count: 32), verifyKey: Data(repeating: 0x02, count: 32))
    var packet = Data()
    packet.append(PacketHeader.encode(opcode: .controlV1, keyID: 0))
    packet.append(Data(repeating: 0x55, count: 8))
    packet.append(Data([0]))
    packet.append(UInt32(10).bigEndianBytes)
    packet.append(Data("hello".utf8))

    guard var wrapped = auth.wrap(packet: packet) else {
        Issue.record("wrap failed")
        return
    }
    wrapped[wrapped.count - 1] ^= 0xFF  // flip payload bit
    #expect(auth.unwrap(wrapped) == nil)
}

// MARK: - Data channel crypto

@Test("CBC round-trip preserves plaintext")
func testCBCRoundTrip() throws {
    let key = Data(repeating: 0x11, count: 32)
    let hmacKey = Data(repeating: 0x22, count: 64)
    let keys = DataChannelKeySet(
        cipher: .aes256CBC,
        digest: .sha512,
        encryptKey: key,
        encryptHMAC: hmacKey,
        decryptKey: key,
        decryptHMAC: hmacKey
    )
    let crypto = DataChannelCrypto(keys: keys, replay: nil)
    let payload = Data("hello tunnel".utf8)
    let packet = try crypto.encrypt(plaintext: payload, packetID: 1, peerID: 7, keyID: 0)

    // layout: [hdr 4][hmac 64][iv 16][ct]
    #expect(packet.count > 4 + 64 + 16)
    var decryptor = crypto
    let plain = try decryptor.decrypt(packet, keyID: 0)
    #expect(plain == payload)
}

@Test("CBC rejects tampered packets")
func testCBCTamper() throws {
    let keys = DataChannelKeySet(
        cipher: .aes256CBC,
        digest: .sha512,
        encryptKey: Data(repeating: 0x11, count: 32),
        encryptHMAC: Data(repeating: 0x22, count: 64),
        decryptKey: Data(repeating: 0x33, count: 32),
        decryptHMAC: Data(repeating: 0x44, count: 64)
    )
    let crypto = DataChannelCrypto(keys: keys)
    var packet = try crypto.encrypt(plaintext: Data("hello".utf8), packetID: 1, peerID: 7, keyID: 0)
    packet[packet.count - 1] ^= 0x01
    var decryptor = crypto
    #expect(throws: DataChannelError.self) {
        _ = try decryptor.decrypt(packet, keyID: 0)
    }
}

@Test("GCM round-trip preserves plaintext")
func testGCMRoundTrip() throws {
    let key = Data(repeating: 0x11, count: 16)
    let implicitIV = Data(repeating: 0x22, count: 8)
    let keys = DataChannelKeySet(
        cipher: .aes128GCM,
        digest: .sha256,
        encryptKey: key,
        encryptHMAC: implicitIV,
        decryptKey: key,
        decryptHMAC: implicitIV
    )
    let crypto = DataChannelCrypto(keys: keys)
    let payload = Data(repeating: 0xAB, count: 100)
    let packet = try crypto.encrypt(plaintext: payload, packetID: 9, peerID: 1, keyID: 0)

    // layout: [hdr 4][pid 4][tag 16][ct]
    #expect(packet.count == 4 + 4 + 16 + payload.count)
    var decryptor = crypto
    let plain = try decryptor.decrypt(packet, keyID: 0)
    #expect(plain == payload)
}

@Test("GCM rejects tampered ciphertext")
func testGCMTamper() throws {
    let keys = DataChannelKeySet(
        cipher: .aes128GCM,
        digest: .sha256,
        encryptKey: Data(repeating: 0x11, count: 16),
        encryptHMAC: Data(repeating: 0x22, count: 8),
        decryptKey: Data(repeating: 0x33, count: 16),
        decryptHMAC: Data(repeating: 0x44, count: 8)
    )
    let crypto = DataChannelCrypto(keys: keys)
    var packet = try crypto.encrypt(plaintext: Data("hello".utf8), packetID: 9, peerID: 1, keyID: 0)
    packet[packet.count - 1] ^= 0x01
    var decryptor = crypto
    #expect(throws: DataChannelError.self) {
        _ = try decryptor.decrypt(packet, keyID: 0)
    }
}

// MARK: - Static key files

@Test("parses OpenVPN static key files")
func testStaticKeyParse() throws {
    let keyHex1 = String(repeating: "ab", count: 64)
    let keyHex2 = String(repeating: "cd", count: 64)
    let keyHex3 = String(repeating: "ef", count: 64)
    let keyHex4 = String(repeating: "12", count: 64)
    let pem = """
    -----BEGIN OpenVPN Static key V1-----
    \(keyHex1)

    \(keyHex2)

    \(keyHex3)

    \(keyHex4)
    -----END OpenVPN Static key V1-----
    """
    let key = try OpenVPNStaticKey.parse(pem: pem)
    #expect(key.cipherKey1 == Data(repeating: 0xAB, count: 64))
    #expect(key.hmacKey1 == Data(repeating: 0xCD, count: 64))
    #expect(key.cipherKey2 == Data(repeating: 0xEF, count: 64))
    #expect(key.hmacKey2 == Data(repeating: 0x12, count: 64))
}

// MARK: - Key expansion

@Test("OpenVPN PRF matches known-answer vector")
func testOpenVPNPRF() throws {
    // Deterministic inputs
    let preMaster = Data((0..<48).map { UInt8($0) })
    let clientRandom1 = Data((100..<132).map { UInt8($0) })
    let serverRandom1 = Data((200..<232).map { UInt8($0) })
    let clientRandom2 = Data((0..<32).map { UInt8($0) })
    let serverRandom2 = Data((32..<64).map { UInt8($0) })
    let clientSID = Data([1, 2, 3, 4, 5, 6, 7, 8])
    let serverSID = Data([9, 10, 11, 12, 13, 14, 15, 16])

    let master = OpenVPNPRF.derive(
        secret: preMaster, label: "OpenVPN master secret",
        clientSeed: clientRandom1, serverSeed: serverRandom1, outputLength: 48
    )
    let expansion = OpenVPNPRF.derive(
        secret: master!,
        label: "OpenVPN key expansion",
        clientSeed: clientRandom2, serverSeed: serverRandom2,
        clientSessionID: clientSID, serverSessionID: serverSID,
        outputLength: KeyExpansion.keyMaterialLength
    )
    #expect(master != nil)
    #expect(expansion != nil)
    #expect(expansion?.count == KeyExpansion.keyMaterialLength)
    // Full expected vectors are verified against OpenVPN's own PRF
    // implementation in the integration test (real server handshake).
}

@Test("key_method_2 client message layout")
func testKeyMethod2Encode() {
    let material = KeyMethod2.ClientMaterial(
        preMaster: Data(repeating: 0x01, count: 48),
        random1: Data(repeating: 0x02, count: 32),
        random2: Data(repeating: 0x03, count: 32),
        options: "V4,dev-type tun,key-method 2,tls-client",
        username: "user",
        password: "pass",
        peerInfo: "IV_VER=2.6.13\nIV_PROTO=2\n"
    )
    let data = KeyMethod2.encode(client: material)
    let optionsString = "V4,dev-type tun,key-method 2,tls-client"
    // [u32 0][u8 2][48][32][32] = 117 header bytes,
    // then length-prefixed strings ([u16 len][bytes\0]).
    #expect(data.prefix(5) == Data([0, 0, 0, 0, 2]))
    #expect(data[5..<53] == Data(repeating: 0x01, count: 48))
    #expect(data[53..<85] == Data(repeating: 0x02, count: 32))
    #expect(data[85..<117] == Data(repeating: 0x03, count: 32))
    let optLen = Int(data[117]) << 8 | Int(data[118])
    #expect(optLen == optionsString.utf8.count + 1)
    let options = String(data: data[119..<(119 + optionsString.utf8.count)], encoding: .utf8)
    #expect(options == optionsString)
}

@Test("key_method_2 server message parse")
func testKeyMethod2ServerParse() {
    var data = Data()
    data.append(contentsOf: [0, 0, 0, 0])
    data.append(2)
    data.append(Data(repeating: 0x0A, count: 32))
    data.append(Data(repeating: 0x0B, count: 32))
    let options = "V4,dev-type tun,tls-server"
    let optLen = UInt16(options.utf8.count + 1)
    data.append(UInt8(optLen >> 8))
    data.append(UInt8(optLen & 0xFF))
    data.append(Data(options.utf8))
    data.append(0)
    data.append(0) // empty username
    data.append(0) // empty password
    data.append(0) // empty peer info

    let parsed = KeyMethod2.parse(server: data)
    #expect(parsed != nil)
    #expect(parsed?.random1 == Data(repeating: 0x0A, count: 32))
    #expect(parsed?.random2 == Data(repeating: 0x0B, count: 32))
    #expect(parsed?.options == "V4,dev-type tun,tls-server")
}

// MARK: - PUSH messages

@Test("parses PUSH_REPLY with base64 options")
func testPushReplyParse() throws {
    let encoded = Data("redirect-gateway def1".utf8).base64EncodedString()
    let payload = Data("PUSH_REPLY,peer-id 17,cipher AES-128-GCM,auth SHA256,key-derivation tls-ekm,ping 10,ping-restart 60,base64,\(encoded)".utf8)

    guard case .reply(let pushed) = try PushParser.parseReply(payload) else {
        Issue.record("expected reply")
        return
    }
    #expect(pushed.peerID == 17)
    #expect(pushed.cipher == .aes128GCM)
    #expect(pushed.digest == .sha256)
    #expect(pushed.useTLSKeyExport)
    #expect(pushed.pingSeconds == 10)
    #expect(pushed.pingRestartSeconds == 60)
    #expect(pushed.raw.contains("redirect-gateway def1"))
}

@Test("parses ifconfig, route-gateway, topology and dns from PUSH_REPLY")
func testPushReplyIfconfigParse() throws {
    let payload = Data("PUSH_REPLY,route-gateway 10.9.0.1,topology subnet,ping 10,ping-restart 60,ifconfig 10.9.0.2 255.255.255.0,peer-id 0,cipher AES-256-GCM,dns 1.1.1.1 1.0.0.1".utf8)

    guard case .reply(let pushed) = try PushParser.parseReply(payload) else {
        Issue.record("expected reply")
        return
    }
    #expect(pushed.ifconfigLocal == "10.9.0.2")
    #expect(pushed.ifconfigRemote == "255.255.255.0")
    #expect(pushed.routeGateway == "10.9.0.1")
    #expect(pushed.topology == "subnet")
    #expect(pushed.dnsServers == ["1.1.1.1", "1.0.0.1"])
}

@Test("peer info matches the official client's announcement")
func testPeerInfoContent() throws {
    let info = PeerInfo.build()
    #expect(info.contains("IV_VER=2.7.6"))
    #expect(info.contains("IV_NCP=2"))
    #expect(info.contains("IV_PROTO=8094"))
    #expect(info.contains("IV_MTU=1600"))
    #expect(info.contains("IV_CIPHERS=AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305"))
    #expect(!info.contains("CBC"))
    #expect(info.contains("IV_COMP_STUBv2=1"))
}

@Test("classifies AUTH_FAILED")
func testPushAuthFailed() throws {
    let payload = Data("AUTH_FAILED,invalid credentials".utf8)
    guard case .authFailed(let reason) = try PushParser.parseReply(payload) else {
        Issue.record("expected auth failure")
        return
    }
    #expect(reason == "invalid credentials")
}

@Test("aead-epoch packet round-trip and key derivation")
func testAEADEpochRoundTrip() throws {
    // Deterministic 256-byte EKM material.
    var material = Data(repeating: 0xAB, count: 256)
    material[0] = 0x01
    material[32] = 0x02
    material[128] = 0x03
    material[160] = 0x04

    let epochKeys = try #require(KeyExpansion.epochKeySet(material: material, cipher: .aes256GCM))
    let classic = DataChannelKeySet(
        cipher: .aes256GCM, digest: .sha256,
        encryptKey: Data(repeating: 0, count: 32), encryptHMAC: Data(repeating: 0, count: 12),
        decryptKey: Data(repeating: 0, count: 32), decryptHMAC: Data(repeating: 0, count: 12)
    )
    let crypto = DataChannelCrypto(keys: classic, epochKeys: epochKeys)

    let plaintext = Data("hello epoch".utf8)
    let packet = try crypto.encrypt(plaintext: plaintext, packetID: 1, peerID: 0, keyID: 0)
    #expect(packet.count == 4 + 8 + 16 + plaintext.count)
    // Header opcode is P_DATA_V2 (9), epoch-pid big-endian.
    #expect(packet[0] >> 3 == 9)
    #expect(packet[4..<6] == Data([0x00, 0x01]))

    // Same-direction round trip: decrypt with the send keys.
    let sendCrypto = DataChannelCrypto(keys: classic, epochKeys: DataChannelEpochKeySet(
        cipher: .aes256GCM,
        sendKey: epochKeys.sendKey, sendIV: epochKeys.sendIV,
        recvKey: epochKeys.sendKey, recvIV: epochKeys.sendIV
    ))
    var decryptor = sendCrypto
    let decrypted = try decryptor.decrypt(packet, keyID: 0)
    #expect(decrypted == plaintext)
}

@Test("epoch key derivation matches the OpenVPN server's logged keys")
func testAEADEpochKeyDerivation() throws {
    var material = Data(repeating: 0x42, count: 256)
    material[0] = 0x5A
    let epochKeys = try #require(KeyExpansion.epochKeySet(material: material, cipher: .aes256GCM))
    // The expand-label output must be deterministic and 32/12 bytes.
    #expect(epochKeys.sendKey.count == 32)
    #expect(epochKeys.recvKey.count == 32)
    #expect(epochKeys.sendIV.count == 12)
    #expect(epochKeys.recvIV.count == 12)
    // send/recv derive from different secrets (client sends with slot 1).
    #expect(epochKeys.sendKey != epochKeys.recvKey)
    let again = try #require(KeyExpansion.epochKeySet(material: material, cipher: .aes256GCM))
    #expect(again.sendKey == epochKeys.sendKey)
    #expect(again.recvIV == epochKeys.recvIV)
}

// MARK: - Replay window

@Test("replay window accepts sequential and out-of-order ids")
func testReplayWindowAccepts() {
    var window = ReplayWindow(windowSize: 64)
    let a1 = window.accept(1)
    let a2 = window.accept(2)
    let a5 = window.accept(5)
    let a4 = window.accept(4)   // out of order but inside the window
    let a3 = window.accept(3)
    let d4 = window.accept(4)   // duplicate
    let d5 = window.accept(5)   // duplicate
    let a6 = window.accept(6)
    #expect(a1 && a2 && a5 && a4 && a3 && a6)
    #expect(!d4)
    #expect(!d5)
}

@Test("replay window rejects ids older than the window")
func testReplayWindowRejectsOld() {
    var window = ReplayWindow(windowSize: 64)
    let a100 = window.accept(100)
    let a37 = window.accept(37)   // 100 - 63: oldest id still inside
    let r36 = window.accept(36)
    let r1 = window.accept(1)
    let a101 = window.accept(101)
    #expect(a100 && a37 && a101)
    #expect(!r36)
    #expect(!r1)
}

@Test("replay window survives long sequences and big shifts")
func testReplayWindowShift() {
    var window = ReplayWindow(windowSize: 64)
    var allAccepted = true
    for id in UInt64(1)...1000 {
        if !window.accept(id) { allAccepted = false }
    }
    #expect(allAccepted)
    let r950 = window.accept(950)
    let r1000 = window.accept(1000)
    let a1001 = window.accept(1001)
    // A jump past the window clears it: ids just below the new highest
    // were never seen, so the first one is accepted (as in OpenVPN's
    // packet_id.c); ids older than the window are still rejected.
    let a2000 = window.accept(2000)
    let a1999 = window.accept(1999)
    let r1930 = window.accept(1930)   // older than the window now
    let a2001 = window.accept(2001)
    #expect(a1001 && a2000 && a1999 && a2001)
    #expect(!r950 && !r1000 && !r1930)
}

@Test("replay window reset clears all state")
func testReplayWindowReset() {
    var window = ReplayWindow(windowSize: 64)
    let a1 = window.accept(10)
    let d1 = window.accept(10)
    window.reset()
    let a2 = window.accept(10)
    let a3 = window.accept(5)
    #expect(a1 && !d1 && a2 && a3)
}

// MARK: - Data channel replay filtering

@Test("PUSH_REPLY trailing NUL does not corrupt the last option")
func testPushReplyTrailingNUL() throws {
    // Live capture: this server's PUSH_REPLY ends with "cipher ... " and
    // the NUL terminator corrupted the trailing option's parsing.
    let reply = "PUSH_REPLY,redirect-gateway def1 bypass-dhcp,dhcp-option DNS 8.8.8.8,route-gateway 10.8.0.1,topology subnet,ping 10,ping-restart 120,ifconfig 10.8.0.4 255.255.255.0,peer-id 1,cipher AES-256-GCM "
    let payload = Data(reply.utf8) + Data([0x00])

    guard case .reply(let pushed) = try PushParser.parseReply(payload) else {
        Issue.record("expected reply")
        return
    }
    #expect(pushed.cipher == .aes256GCM)
    #expect(pushed.peerID == 1)
    #expect(pushed.ifconfigLocal == "10.8.0.4")
}

private func makeGCMCrypto(epochKeys: DataChannelEpochKeySet? = nil) -> DataChannelCrypto {
    let keys = DataChannelKeySet(
        cipher: .aes128GCM,
        digest: .sha256,
        encryptKey: Data(repeating: 0x11, count: 16),
        encryptHMAC: Data(repeating: 0x22, count: 8),
        decryptKey: Data(repeating: 0x11, count: 16),
        decryptHMAC: Data(repeating: 0x22, count: 8)
    )
    return DataChannelCrypto(keys: keys, epochKeys: epochKeys)
}

@Test("GCM rejects replayed packets")
func testGCMReplayRejected() throws {
    var crypto = makeGCMCrypto()
    let packet = try crypto.encrypt(plaintext: Data("x".utf8), packetID: 7, peerID: 0, keyID: 0)
    _ = try crypto.decrypt(packet, keyID: 0)
    #expect(throws: DataChannelError.replayedPacket) {
        _ = try crypto.decrypt(packet, keyID: 0)
    }
}

@Test("CBC rejects replayed packets")
func testCBCReplayRejected() throws {
    let keys = DataChannelKeySet(
        cipher: .aes256CBC,
        digest: .sha512,
        encryptKey: Data(repeating: 0x11, count: 32),
        encryptHMAC: Data(repeating: 0x22, count: 64),
        decryptKey: Data(repeating: 0x11, count: 32),
        decryptHMAC: Data(repeating: 0x22, count: 64)
    )
    var crypto = DataChannelCrypto(keys: keys)
    let packet = try crypto.encrypt(plaintext: Data("payload".utf8), packetID: 3, peerID: 0, keyID: 0)
    _ = try crypto.decrypt(packet, keyID: 0)
    #expect(throws: DataChannelError.replayedPacket) {
        _ = try crypto.decrypt(packet, keyID: 0)
    }
}

@Test("epoch rejects replayed packets (48-bit counter)")
func testEpochReplayRejected() throws {
    var material = Data(repeating: 0xAB, count: 256)
    material[0] = 0x01
    material[128] = 0x03
    let epochKeys = try #require(KeyExpansion.epochKeySet(material: material, cipher: .aes128GCM))
    // Same-direction round trip: decrypt with the send keys.
    let loopback = DataChannelEpochKeySet(
        cipher: .aes128GCM,
        sendKey: epochKeys.sendKey, sendIV: epochKeys.sendIV,
        recvKey: epochKeys.sendKey, recvIV: epochKeys.sendIV
    )
    var crypto = makeGCMCrypto(epochKeys: loopback)

    let packet1 = try crypto.encrypt(plaintext: Data("one".utf8), packetID: 1, peerID: 0, keyID: 0)
    let packet2 = try crypto.encrypt(plaintext: Data("two".utf8), packetID: 2, peerID: 0, keyID: 0)
    _ = try crypto.decrypt(packet1, keyID: 0)
    _ = try crypto.decrypt(packet2, keyID: 0)
    #expect(throws: DataChannelError.replayedPacket) {
        _ = try crypto.decrypt(packet1, keyID: 0)
    }
    #expect(throws: DataChannelError.replayedPacket) {
        _ = try crypto.decrypt(packet2, keyID: 0)
    }
}

@Test("failed decryption does not advance the replay filter")
func testReplayFilterNotAdvancedOnDecryptFailure() throws {
    var crypto = makeGCMCrypto()
    let one = try crypto.encrypt(plaintext: Data("one".utf8), packetID: 1, peerID: 0, keyID: 0)
    let two = try crypto.encrypt(plaintext: Data("two".utf8), packetID: 2, peerID: 0, keyID: 0)
    var tampered = two
    tampered[tampered.count - 1] ^= 0xFF

    _ = try crypto.decrypt(one, keyID: 0)
    // The tampered packet fails its tag; the filter must not record pid 2.
    #expect(throws: DataChannelError.self) {
        _ = try crypto.decrypt(tampered, keyID: 0)
    }
    // pid 2 is therefore still new and decrypts fine afterwards.
    _ = try crypto.decrypt(two, keyID: 0)
    // But once seen, both are replays.
    #expect(throws: DataChannelError.replayedPacket) {
        _ = try crypto.decrypt(one, keyID: 0)
    }
    #expect(throws: DataChannelError.replayedPacket) {
        _ = try crypto.decrypt(two, keyID: 0)
    }
}

@Test("epoch wire packet-id encodes 48-bit counters")
func testEpochPacketIDEncoding() {
    #expect(DataChannelCrypto.epochPacketID(epoch: 1, counter: 1) == Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]))
    let large = DataChannelCrypto.epochPacketID(epoch: 1, counter: 0xFFFF_FFFF_FFFF)
    #expect(large == Data([0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
}

@Test("P_DATA_V1 round-trips without peer-id header")
func testDataV1RoundTrip() throws {
    var crypto = makeGCMCrypto()
    let payload = Data("v1 ping".utf8)
    let packet = try crypto.encrypt(plaintext: payload, packetID: 5, peerID: 0, keyID: 0, useV1Header: true)

    // V1: single header byte with opcode 6, then pid(4)+tag(16)+ct.
    #expect(packet.count == 1 + 4 + 16 + payload.count)
    let (opcode, _) = PacketHeader.decode(packet[0])
    #expect(opcode == .dataV1)

    let plain = try crypto.decrypt(packet, keyID: 0)
    #expect(plain == payload)
}

@Test("classic AEAD AAD self-adjusts to pid-only servers")
func testClassicAADFallback() throws {
    // A pid-only server: packet authenticates without the header in the AAD.
    var pidOnlyCrypto = makeGCMCrypto()
    pidOnlyCrypto.classicAADIncludesHeader = false
    let packet = try pidOnlyCrypto.encrypt(plaintext: Data("x".utf8), packetID: 9, peerID: 0, keyID: 0)

    // Our default (header+pid AAD) client still decrypts it and adapts.
    var client = makeGCMCrypto()
    #expect(client.classicAADIncludesHeader)
    let plain = try client.decrypt(packet, keyID: 0)
    #expect(plain == Data("x".utf8))
    #expect(!client.classicAADIncludesHeader)
    // And now sends pid-only itself.
    let reply = try client.encrypt(plaintext: Data("y".utf8), packetID: 1, peerID: 0, keyID: 0)
    _ = try pidOnlyCrypto.decrypt(reply, keyID: 0)
}

// MARK: - Profile misc

@Test("parses replay-window directive")
func testReplayWindowDirective() throws {
    let profile = try OVPNParser().parse("remote a.example.com 1194\nreplay-window 128\n")
    #expect(profile.replayWindow == 128)
    let defaultProfile = try OVPNParser().parse("remote a.example.com 1194\n")
    #expect(defaultProfile.replayWindow == nil)
}

// MARK: - TCP framing

@Test("TCP framer round-trips packets split across arbitrary feed sizes")
func testTCPPacketFramerRoundTrip() throws {
    let packetA = Data([0x38, 0x00, 0x01, 0x02, 0x03])
    let packetB = Data(repeating: 0xAB, count: 300)   // longer than 255: exercises both length bytes
    let packetC = Data([0x10, 0x99])

    var wire = Data()
    wire.append(TCPPacketFramer.frame(packetA))
    wire.append(TCPPacketFramer.frame(packetB))
    wire.append(TCPPacketFramer.frame(packetC))

    var framer = TCPPacketFramer()
    var received: [Data] = []
    // Feed one byte at a time: packets may only be delivered once complete.
    for byte in wire {
        received.append(contentsOf: try framer.feed(Data([byte])))
    }
    #expect(received.count == 3)
    #expect(received[0] == packetA)
    #expect(received[1] == packetB)
    #expect(received[2] == packetC)
    #expect(!framer.hasPartialData)
}

@Test("TCP framer rejects zero-length frames")
func testTCPPacketFramerZeroLength() {
    var framer = TCPPacketFramer()
    #expect(throws: OpenVPNProtocolError.self) {
        _ = try framer.feed(Data([0x00, 0x00, 0x01, 0x02]))
    }
}

@Test("TCP framer keeps partial packets buffered")
func testTCPPacketFramerPartial() throws {
    let packet = Data([0x41, 0x42, 0x43])
    var wire = TCPPacketFramer.frame(packet)
    var framer = TCPPacketFramer()

    let first = try framer.feed(wire.prefix(4))   // header + 2 of 3 payload bytes
    #expect(first.isEmpty)
    #expect(framer.hasPartialData)

    let rest = try framer.feed(wire.suffix(1))
    #expect(rest == [packet])
    #expect(!framer.hasPartialData)
}
