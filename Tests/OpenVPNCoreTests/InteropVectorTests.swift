import Testing
import Foundation
@testable import OpenVPNCore

// Known-answer vectors captured from a real OpenVPN 2.7.7 server
// (Scripts/integration-tests.sh setup). The static key is a throwaway test
// key generated with `openvpn --genkey secret`.

let interopStaticKeyPEM = """
-----BEGIN OpenVPN Static key V1-----
e54b0c8b9c76d04b1f1584ff8fc4b9d2
6f9cfb86cd87d7595d079b46bd87c26c
da1fb834b1075233f76771aa4808c5e3
104688268bcb16bc8ba0ae7604a01a46
891061d4fdc56fc0b9bda7771ade13b2
b65102481d7f2d345aca68a8ee8d63e6
74ea9adb75c0bac129eabe94f719e341
400a5fae3455e9f22bc424fc91fc82b3
bdb89b071c58d092b56f07e00e61d9ef
40bf044bc4a51c1386f98e7d03ed901c
e732b5e97321ec0451327e689b275483
7f1ecf7baa2338d7b59cfc156c671705
c27cb274aedd06e3fbc9d98dbddfba55
cae367a738f53ab88f1d75beaf986aa1
7430cba81238a0e136f56aa8975e70c6
c2e6b240a9da9b653ebbdb6ab2cc99f1
-----END OpenVPN Static key V1-----
"""

func hexData(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

/// P_CONTROL_HARD_RESET_SERVER_V2 sent by a server running
/// `tls-auth ta.key 0` with `auth SHA256`.
let serverResetSHA256 = hexData(
    "4010c1d490011c569488291d985e733acb987ea3100c972554aa3f043060d87f90cf9bd532c5be40" +
    "3e000000016abfc3db01000000009aafe5091de872fa00000000"
)

/// The same with `auth SHA1` (20-byte HMAC).
let serverResetSHA1 = hexData(
    "40f6f19de401f95edf76116a7432a577478bd0c4e5e72b273dd5bf9177000000016abfc3dc0100" +
    "00000057f707610e349b8800000000"
)

@Test("tls-auth verifies a real OpenVPN SHA256 packet (HMAC key truncated to digest size)")
func testTLSAuthSHA256KnownAnswer() throws {
    let key = try OpenVPNStaticKey.parse(pem: interopStaticKeyPEM)
    let keys = key.tlsAuthKeys(direction: 1)
    let auth = TLSAuth(digest: .sha256, sendKey: keys.send, verifyKey: keys.verify)
    let unwrapped = try #require(auth.unwrap(serverResetSHA256))
    let (opcode, _) = PacketHeader.decode(unwrapped[0])
    #expect(opcode == .controlHardResetServerV2)

    var tampered = serverResetSHA256
    tampered[tampered.count - 1] ^= 0x01
    #expect(auth.unwrap(tampered) == nil)
}

@Test("tls-auth verifies a real OpenVPN SHA1 packet")
func testTLSAuthSHA1KnownAnswer() throws {
    let key = try OpenVPNStaticKey.parse(pem: interopStaticKeyPEM)
    let keys = key.tlsAuthKeys(direction: 1)
    let auth = TLSAuth(digest: .sha1, sendKey: keys.send, verifyKey: keys.verify)
    #expect(auth.tagLength == 20)
    #expect(auth.unwrap(serverResetSHA1) != nil)
    // The server signs with keys[0]: verifying with keys[1] must fail.
    let wrongDirection = TLSAuth(digest: .sha1, sendKey: keys.verify, verifyKey: keys.send)
    #expect(wrongDirection.unwrap(serverResetSHA1) == nil)
}

@Test("tls-auth key-direction maps onto OpenVPN's key slots")
func testTLSAuthKeyDirections() throws {
    let key = try OpenVPNStaticKey.parse(pem: interopStaticKeyPEM)
    #expect(key.tlsAuthKeys(direction: 1) == (key.hmacKey2, key.hmacKey1))
    #expect(key.tlsAuthKeys(direction: 0) == (key.hmacKey1, key.hmacKey2))
    #expect(key.tlsAuthKeys(direction: nil) == (key.hmacKey1, key.hmacKey1))
    #expect(key.rawKeyMaterial.count == 256)
}

@Test("auth defaults to SHA1 like OpenVPN")
func testDefaultDigest() throws {
    let profile = try OVPNParser().parse("remote vpn.example.com 1194")
    #expect(profile.digest == nil)
    #expect(profile.effectiveDigest == .sha1)
}
