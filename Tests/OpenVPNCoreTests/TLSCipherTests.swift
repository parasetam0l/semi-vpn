import Testing
@testable import OpenVPNCore

/// The TLS context applies tls-cipher and tls-ciphersuites before it loads
/// the CA, so with a placeholder CA a usable list fails on the CA instead.
private func contextError(cipherList: String? = nil, cipherSuites: String? = nil) -> String {
    do {
        _ = try TLSEngine(caPEM: "not a certificate", certPEM: nil, keyPEM: nil,
                          cipherList: cipherList, cipherSuites: cipherSuites)
        return ""
    } catch {
        return "\(error)"
    }
}

@Test("tls-cipher takes OpenVPN's IANA names, OpenSSL names and keywords", arguments: [
    "TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256",
    "TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384",
    "TLS-ECDHE-RSA-WITH-CHACHA20-POLY1305-SHA256",
    "TLS-DHE-RSA-WITH-AES-256-GCM-SHA384",
    "TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256:TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256",
    "ECDHE-ECDSA-AES128-GCM-SHA256",
    "TLS-NOT-A-CIPHER:ECDHE-RSA-AES128-GCM-SHA256",
    "DEFAULT:!aNULL",
])
func tlsCipherAccepted(list: String) {
    let error = contextError(cipherList: list)
    #expect(!error.isEmpty)
    #expect(!error.contains("tls-cipher"))
}

@Test("tls-cipher without a usable suite is an error that quotes it")
func tlsCipherRejected() {
    let error = contextError(cipherList: "TLS-NOT-A-CIPHER")
    #expect(error.contains("tls-cipher"))
    #expect(error.contains("TLS-NOT-A-CIPHER"))
}

@Test("tls-ciphersuites takes '-' for '_' like OpenVPN", arguments: [
    "TLS_AES_256_GCM_SHA384",
    "TLS-AES-256-GCM-SHA384:TLS-CHACHA20-POLY1305-SHA256",
])
func tlsCiphersuitesAccepted(list: String) {
    let error = contextError(cipherSuites: list)
    #expect(!error.isEmpty)
    #expect(!error.contains("tls-ciphersuites"))
}
