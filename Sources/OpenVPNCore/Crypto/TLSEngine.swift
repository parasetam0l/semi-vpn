import Foundation
import COpenVPNTLS

public enum TLSEngineError: Error, Sendable, Equatable {
    case contextCreation(String)
    case connectionCreation(String)
    case handshakeFailed(String)
    case peerVerificationFailed(String)
    case writeFailed
    case closed
}

/// Swift wrapper around the OpenSSL control-channel shim.
///
/// The engine owns a TLS session whose transport is a pair of memory BIOs.
/// Ciphertext is exchanged with the reliable control-channel layer:
/// `drainCiphertext()` returns bytes to send, `feedCiphertext()` accepts
/// received bytes.
public final class TLSEngine: @unchecked Sendable {
    private let ctxPointer: OpaquePointer
    private let connPointer: OpaquePointer
    private let peerName: String

    /// How the server certificate name is matched (`verify-x509-name`).
    public enum X509NameMatch: Sendable, Equatable {
        case commonName(String)
        case commonNamePrefix(String)
        case subject(String)
    }

    public init(
        caPEM: String,
        certPEM: String?,
        keyPEM: String?,
        peerName: String = ""
    ) throws {
        let ca = caPEM
        let cert = certPEM ?? ""
        let key = keyPEM ?? ""
        guard let ctx = ovpn_tls_ctx_new(ca, cert, key) else {
            throw TLSEngineError.contextCreation(String(decoding: unsafeUnwrapCString(ovpn_tls_ctx_error(nil)), as: UTF8.self))
        }
        ctxPointer = ctx
        guard let conn = ovpn_tls_conn_new(ctx) else {
            ovpn_tls_ctx_free(ctx)
            throw TLSEngineError.connectionCreation(String(decoding: unsafeUnwrapCString(ovpn_tls_ctx_error(ctx)), as: UTF8.self))
        }
        connPointer = conn
        self.peerName = peerName
    }

    deinit {
        ovpn_tls_conn_free(connPointer)
        ovpn_tls_ctx_free(ctxPointer)
    }

    // MARK: - Handshake

    /// Advances the TLS handshake. Returns the action the caller should take.
    public enum HandshakeResult: Sendable {
        case done
        case needsSend         // ciphertext is pending in the output BIO
        case waiting           // waiting for more ciphertext from the peer
    }

    public func handshake() throws -> HandshakeResult {
        switch ovpn_tls_handshake(connPointer) {
        case OVPN_TLS_OK:
            return .done
        case OVPN_TLS_WANT_READ:
            return .waiting
        case OVPN_TLS_WANT_WRITE:
            return .needsSend
        default:
            throw TLSEngineError.handshakeFailed(String(decoding: unsafeUnwrapCString(ovpn_tls_conn_error(connPointer)), as: UTF8.self))
        }
    }

    public var isHandshaken: Bool {
        ovpn_tls_is_handshaken(connPointer) != 0
    }

    // MARK: - Peer verification

    /// Verifies the peer certificate once the handshake has completed.
    /// The CA chain is checked by OpenSSL itself (`SSL_VERIFY_PEER`); this
    /// adds the profile's `remote-cert-tls` and `verify-x509-name` checks.
    /// Must be called before any application data is sent.
    public func verifyPeer(requireServerEKU: Bool, name: X509NameMatch?) throws {
        let (kind, value): (ovpn_x509_name_kind, String)
        switch name {
        case .commonName(let n): (kind, value) = (OVPN_X509_NAME, n)
        case .commonNamePrefix(let n): (kind, value) = (OVPN_X509_NAME_PREFIX, n)
        case .subject(let n): (kind, value) = (OVPN_X509_SUBJECT, n)
        case nil: (kind, value) = (OVPN_X509_NAME, "")
        }
        let rc = value.withCString { cName in
            ovpn_tls_verify_peer(connPointer, requireServerEKU ? 1 : 0, Int32(kind.rawValue), cName)
        }
        guard rc == 1 else {
            throw TLSEngineError.peerVerificationFailed(
                String(decoding: unsafeUnwrapCString(ovpn_tls_conn_error(connPointer)), as: UTF8.self)
            )
        }
    }

    // MARK: - Application data

    /// Feeds a plaintext application message into TLS.
    @discardableResult
    public func writePlaintext(_ data: Data) throws -> Int {
        let rc = data.withUnsafeBytes { ptr in
            ovpn_tls_write(connPointer, ptr.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        guard rc >= 0 else { throw TLSEngineError.writeFailed }
        return Int(rc)
    }

    /// Reads a complete application message if one is available.
    public func readPlaintext() throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let rc = ovpn_tls_read(connPointer, &buffer, buffer.count)
        if rc > 0 {
            return Data(buffer.prefix(Int(rc)))
        }
        if rc == 0 { return nil }
        throw TLSEngineError.closed
    }

    // MARK: - Transport

    public var ciphertextPending: Int {
        Int(ovpn_tls_out_pending(connPointer))
    }

    /// Drains all pending ciphertext (one TLS record at a time is typical).
    public func drainCiphertext() -> Data {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var out = Data()
        while ovpn_tls_out_pending(connPointer) > 0 {
            let rc = Int(ovpn_tls_drain(connPointer, &buffer, buffer.count))
            guard rc > 0 else { break }
            out.append(contentsOf: buffer.prefix(rc))
        }
        return out
    }

    public func feedCiphertext(_ data: Data) {
        data.withUnsafeBytes { ptr in
            ovpn_tls_feed(connPointer, ptr.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
    }

    // MARK: - Key material

    /// RFC 5705 keying-material export (OpenVPN label).
    public func exportKeyMaterial(label: String, length: Int) -> Data? {
        var out = [UInt8](repeating: 0, count: length)
        let rc = ovpn_tls_export_key(connPointer, label, &out, length)
        guard rc != 0 else { return nil }
        return Data(out)
    }

    /// Peer certificate subject (RFC2253), for verification logging.
    public var peerSubject: String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let rc = ovpn_tls_get_server_cert_subject(connPointer, &buffer, buffer.count)
        guard rc != 0 else { return nil }
        return String(decoding: unsafeUnwrapCString(buffer), as: UTF8.self)
    }
}

private func unsafeUnwrapCString(_ pointer: UnsafePointer<CChar>?) -> [UInt8] {
    guard let pointer else { return [] }
    var bytes: [UInt8] = []
    var cursor = pointer
    while cursor.pointee != 0 {
        bytes.append(UInt8(bitPattern: cursor.pointee))
        cursor = cursor.advanced(by: 1)
    }
    return bytes
}
