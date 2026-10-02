#ifndef OVPN_TLS_H
#define OVPN_TLS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * OpenSSL 3 TLS shim for the OpenVPN control channel.
 * Drives a client TLS session over memory BIOs so the handshake and
 * application data can be carried inside OpenVPN P_CONTROL packets
 * over UDP.
 */

typedef struct ovpn_tls_ctx ovpn_tls_ctx;
typedef struct ovpn_tls_conn ovpn_tls_conn;

typedef enum {
    OVPN_TLS_OK = 0,
    OVPN_TLS_WANT_READ = 1,
    OVPN_TLS_WANT_WRITE = 2,
    OVPN_TLS_FAILED = -1
} ovpn_tls_status;

typedef enum {
    OVPN_X509_NAME = 0,        /* commonName equals name */
    OVPN_X509_NAME_PREFIX = 1, /* commonName starts with name */
    OVPN_X509_SUBJECT = 2      /* full subject DN (OpenVPN's "C=.., O=.., CN=..") equals name */
} ovpn_x509_name_kind;

/*
 * Client TLS configuration. Strings may be NULL or empty when unused.
 * - cert_pem: the client certificate, optionally followed by its chain
 * - extra_certs_pem: additional chain certificates (extra-certs)
 * - key_password: passphrase of an encrypted key; never prompted for
 * - min_version: 0 for the default (TLS 1.2), else e.g. TLS1_3_VERSION
 * - cipher_list / ciphersuites: tls-cipher / tls-ciphersuites
 */
typedef struct {
    const char *ca_pem;
    const char *cert_pem;
    const char *extra_certs_pem;
    const char *key_pem;
    const char *key_password;
    int min_version;
    const char *cipher_list;
    const char *ciphersuites;
} ovpn_tls_config;

/* Creates a context. On failure returns NULL and, when err/err_len are
 * given, writes the reason there. */
ovpn_tls_ctx *ovpn_tls_ctx_new(const ovpn_tls_config *config, char *err, size_t err_len);
const char *ovpn_tls_ctx_error(const ovpn_tls_ctx *t);
void ovpn_tls_ctx_free(ovpn_tls_ctx *t);

ovpn_tls_conn *ovpn_tls_conn_new(ovpn_tls_ctx *t);
const char *ovpn_tls_conn_error(const ovpn_tls_conn *c);
void ovpn_tls_conn_free(ovpn_tls_conn *c);

ovpn_tls_status ovpn_tls_handshake(ovpn_tls_conn *c);
int ovpn_tls_is_handshaken(ovpn_tls_conn *c);

int ovpn_tls_write(ovpn_tls_conn *c, const uint8_t *data, size_t len);
int ovpn_tls_read(ovpn_tls_conn *c, uint8_t *out, size_t cap);

int ovpn_tls_out_pending(ovpn_tls_conn *c);
int ovpn_tls_drain(ovpn_tls_conn *c, uint8_t *out, size_t cap);
void ovpn_tls_feed(ovpn_tls_conn *c, const uint8_t *data, size_t len);

int ovpn_tls_export_key(ovpn_tls_conn *c, const char *label, uint8_t *out, size_t len);
int ovpn_tls_get_server_cert_subject(ovpn_tls_conn *c, char *out, size_t cap);

/*
 * Verifies the peer certificate after the handshake:
 * - the CA chain is already checked by SSL_VERIFY_PEER;
 * - when require_server_eku is set, the certificate must carry a key
 *   usage extension and the TLS Web Server Authentication EKU
 *   (remote-cert-tls server);
 * - when name is non-empty, the subject/commonName is matched per
 *   name_kind (verify-x509-name).
 * Returns 1 on success, 0 on failure (reason in ovpn_tls_conn_error).
 */
int ovpn_tls_verify_peer(ovpn_tls_conn *c, int require_server_eku,
                         int name_kind, const char *name);

#ifdef __cplusplus
}
#endif

#endif /* OVPN_TLS_H */
