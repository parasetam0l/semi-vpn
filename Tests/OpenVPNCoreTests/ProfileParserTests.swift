import Testing
import Foundation
@testable import OpenVPNCore

private let embeddedPKI = """
<ca>
-----BEGIN CERTIFICATE-----
AAAA
-----END CERTIFICATE-----
</ca>
"""

@Test("proto variants map to UDP/TCP with an address-family restriction")
func testProtoVariants() throws {
    let cases: [(String, OVPNProfile.Transport, OVPNProfile.AddressFamily?)] = [
        ("udp", .udp, nil), ("udp4", .udp, .ipv4), ("udp6", .udp, .ipv6),
        ("tcp", .tcp, nil), ("tcp-client", .tcp, nil), ("tcp4-client", .tcp, .ipv4),
        ("TCP6", .tcp, .ipv6), ("tcp4", .tcp, .ipv4),
    ]
    for (proto, transport, family) in cases {
        let profile = try OVPNParser().parse("remote vpn.example.com\nproto \(proto)\n\(embeddedPKI)")
        #expect(profile.transport == transport, "\(proto)")
        #expect(profile.remotes.first?.family == family, "\(proto)")
        #expect(profile.fatalIssues.isEmpty, "\(proto)")
    }
    let server = try OVPNParser().parse("remote vpn.example.com\nproto tcp-server\n\(embeddedPKI)")
    #expect(server.fatalIssues.contains { $0.message.contains("tcp-server") })
}

@Test("cipher, data-ciphers and auth are case-insensitive")
func testCaseInsensitiveCrypto() throws {
    let profile = try OVPNParser().parse("cipher aes-256-gcm\ndata-ciphers aes-128-gcm:CHACHA20-POLY1305:AES-192-GCM\nauth sha256\n")
    #expect(profile.cipher == .aes256GCM)
    #expect(profile.cipherSpecified)
    #expect(profile.digest == .sha256)
    #expect(profile.dataCiphers == [.aes128GCM, .chacha20Poly1305])
    #expect(profile.announcedCiphers == ["AES-128-GCM", "CHACHA20-POLY1305", "AES-256-GCM"])
    #expect(profile.issues.contains { $0.message.contains("AES-192-GCM") })
    // Without a cipher directive, the CBC fallback is not announced.
    #expect(try OVPNParser().parse("remote a").announcedCiphers == PeerInfo.supportedCiphers)
    #expect(try OVPNParser().parse("cipher AES-256-CBC").announcedCiphers.last == "AES-256-CBC")
}

@Test("remotes take their port and proto from the remote line, port, and connection blocks")
func testRemotes() throws {
    let text = """
    proto udp
    port 1195
    remote-random
    remote a.example.com
    remote b.example.com 443 tcp
    remote c.example.com 1196 udp6
    <connection>
    remote d.example.com 8443
    proto tcp-client
    </connection>
    \(embeddedPKI)
    """
    let profile = try OVPNParser().parse(text)
    #expect(profile.remoteRandom)
    #expect(profile.remotes == [
        OVPNProfile.Remote(host: "a.example.com", port: 1195),
        OVPNProfile.Remote(host: "b.example.com", port: 443, transport: .tcp),
        OVPNProfile.Remote(host: "c.example.com", port: 1196, transport: .udp, family: .ipv6),
        OVPNProfile.Remote(host: "d.example.com", port: 8443, transport: .tcp),
    ])
    #expect(profile.transport(for: profile.remotes[0]) == .udp)
    #expect(profile.transport(for: profile.remotes[1]) == .tcp)
}

@Test("tokenizer follows OpenVPN quoting and comment rules")
func testTokenizer() throws {
    #expect(OVPNParser.tokenize("remote host#1 1194 # comment") == ["remote", "host#1", "1194"])
    #expect(OVPNParser.tokenize("  ; full comment") == [])
    #expect(OVPNParser.tokenize("verify-x509-name 'C=TR, CN=srv' subject") == ["verify-x509-name", "C=TR, CN=srv", "subject"])
    #expect(OVPNParser.tokenize("setenv X \"a \\\"b\\\" c\"") == ["setenv", "X", "a \"b\" c"])
    #expect(OVPNParser.tokenize("ca my\\ ca.crt") == ["ca", "my ca.crt"])
}

@Test("verify-x509-name defaults to subject like OpenVPN")
func testVerifyX509Default() throws {
    let single = try OVPNParser().parse("verify-x509-name 'C=TR, O=Example, CN=server'")
    #expect(single.x509NameCheck == .verifyName("C=TR, O=Example, CN=server", .subject))
    let named = try OVPNParser().parse("verify-x509-name server name")
    #expect(named.x509NameCheck == .verifyName("server", .name))
}

@Test("parses keepalive, reneg-sec, hand-window, tun-mtu, askpass and inline credentials")
func testTimersAndCredentials() throws {
    let text = """
    keepalive 15 90
    reneg-sec 1800
    hand-window 30
    tun-mtu 1400
    askpass
    auth-user-pass
    <auth-user-pass>
    alice
    correct horse
    </auth-user-pass>
    <extra-certs>
    -----BEGIN CERTIFICATE-----
    BBBB
    -----END CERTIFICATE-----
    </extra-certs>
    """
    let profile = try OVPNParser().parse(text)
    #expect(profile.pingSeconds == 15)
    #expect(profile.pingRestartSeconds == 90)
    #expect(profile.renegSeconds == 1800)
    #expect(profile.handWindow == 30)
    #expect(profile.tunMTU == 1400)
    #expect(profile.askPass)
    #expect(profile.requiresAuthUserPass)
    #expect(profile.authUserPass == OVPNProfile.AuthUserPass(username: "alice", password: "correct horse"))
    #expect(profile.extraCertsPEM?.contains("BBBB") == true)
}

@Test("reports unsupported features and missing material")
func testIssues() throws {
    let tap = try OVPNParser().parse("remote a\ndev tap0\nsecret static.key\npkcs12 client.p12\nhttp-proxy proxy 8080\ncomp-lzo yes\n\(embeddedPKI)")
    let messages = tap.issues.map(\.message).joined(separator: "\n")
    #expect(messages.contains("dev tap"))
    #expect(messages.contains("Static-key"))
    #expect(messages.contains("pkcs12"))
    #expect(messages.contains("http-proxy"))
    #expect(tap.issues.contains { $0.severity == .warning && $0.message.contains("LZO") })

    let missing = try OVPNParser().parse("remote a\nca ca.crt\ntls-auth ta.key 1")
    #expect(missing.keyDirection == 1)
    #expect(missing.fatalIssues.contains { $0.message.contains("'ca.crt'") })
    #expect(missing.fatalIssues.contains { $0.message.contains("'ta.key'") })
}

@Test("inliner embeds referenced files relative to the profile")
func testInliner() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try "-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----\n".write(to: directory.appendingPathComponent("ca.crt"), atomically: true, encoding: .utf8)
    try "-----BEGIN OpenVPN Static key V1-----\nKEY\n-----END OpenVPN Static key V1-----\n".write(to: directory.appendingPathComponent("my ta.key"), atomically: true, encoding: .utf8)
    try "bob\nhunter2\n".write(to: directory.appendingPathComponent("creds.txt"), atomically: true, encoding: .utf8)

    let text = "remote a\nca ca.crt\ntls-auth \"my ta.key\" 1\nauth-user-pass creds.txt\n"
    let inlined = try OVPNProfileInliner.inline(text, baseDirectory: directory)
    let profile = try OVPNParser().parse(inlined)
    #expect(profile.caPEM?.contains("CA") == true)
    #expect(profile.tlsAuthPEM?.contains("KEY") == true)
    #expect(profile.keyDirection == 1)
    #expect(profile.authUserPass == OVPNProfile.AuthUserPass(username: "bob", password: "hunter2"))
    #expect(profile.fatalIssues.isEmpty)

    #expect(throws: OVPNInlineError.missingFile(directive: "cert", path: "client.crt")) {
        try OVPNProfileInliner.inline("cert client.crt", baseDirectory: directory)
    }
    // Self-contained profiles pass through untouched.
    #expect(try OVPNProfileInliner.inline("remote a\n<ca>\nX\n</ca>", baseDirectory: directory) == "remote a\n<ca>\nX\n</ca>")
}

@Test("parses TLS options and detects encrypted keys")
func testTLSOptions() throws {
    let profile = try OVPNParser().parse("""
    tls-version-min 1.3 or-highest
    tls-cipher ECDHE-ECDSA-AES256-GCM-SHA384
    tls-ciphersuites TLS_AES_256_GCM_SHA384
    <key>
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    AAAA
    -----END ENCRYPTED PRIVATE KEY-----
    </key>
    """)
    #expect(profile.tlsVersionMin == "1.3 or-highest")
    #expect(TLSEngine.protocolVersion(profile.tlsVersionMin) == 0x0304)
    #expect(TLSEngine.protocolVersion("1.2") == 0)
    #expect(profile.tlsCipher == "ECDHE-ECDSA-AES256-GCM-SHA384")
    #expect(profile.tlsCiphersuites == "TLS_AES_256_GCM_SHA384")
    #expect(profile.requiresKeyPassphrase)
    #expect(throws: TLSEngineError.self) {
        try TLSEngine(caPEM: "x", certPEM: "x", keyPEM: profile.keyPEM)
    }
}
