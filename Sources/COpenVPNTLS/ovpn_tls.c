#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ovpn_tls.h"

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/objects.h>

/*
 * Minimal OpenSSL 3 TLS shim for the OpenVPN control channel.
 *
 * Drives a client TLS session over memory BIOs so the handshake and
 * application data can be carried inside OpenVPN P_CONTROL packets
 * over UDP. Also exposes RFC 5705 keying-material export, which
 * OpenVPN uses for data-channel key derivation.
 */

typedef struct ovpn_tls_ctx {
    SSL_CTX *ctx;
    char errbuf[256];
} ovpn_tls_ctx;

typedef struct ovpn_tls_conn {
    SSL *ssl;
    BIO *rbio;
    BIO *wbio;
    ovpn_tls_ctx *parent;
    char errbuf[256];
} ovpn_tls_conn;

static void
keylog_cb(const SSL *ssl, const char *line)
{
    /* Debug aid, off by default: session keys must not silently end up
     * on disk. Enable with OVPN_TLS_DEBUG_KEYLOG=1. */
    if (!getenv("OVPN_TLS_DEBUG_KEYLOG"))
    {
        return;
    }
    FILE *f = fopen("/tmp/tls_keys.log", "a");
    if (f)
    {
        fprintf(f, "%s\n", line);
        fclose(f);
    }
}

static void capture_error(char *buf, size_t len)
{
    unsigned long err = ERR_get_error();
    if (err) {
        ERR_error_string_n(err, buf, len);
    } else {
        snprintf(buf, len, "no error");
    }
}

ovpn_tls_ctx *
ovpn_tls_ctx_new(const char *ca_pem, const char *cert_pem, const char *key_pem)
{
    if (!ca_pem || !cert_pem || !key_pem) {
        return NULL;
    }

    ovpn_tls_ctx *t = calloc(1, sizeof(ovpn_tls_ctx));
    if (!t) {
        return NULL;
    }

    t->ctx = SSL_CTX_new(TLS_client_method());
    if (!t->ctx) {
        capture_error(t->errbuf, sizeof(t->errbuf));
        free(t);
        return NULL;
    }

    /* Control channel: TLS 1.2 minimum; TLS 1.3 preferred when the server
     * supports it (OpenVPN 2.6+ servers negotiate TLS 1.3). */
    SSL_CTX_set_min_proto_version(t->ctx, TLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(t->ctx, TLS1_3_VERSION);

    /* NSS key log for debugging the TLS stream */
    SSL_CTX_set_keylog_callback(t->ctx, keylog_cb);

    /* Load every PEM certificate in the CA block (profiles may carry
     * intermediate chains, not just the root). */
    {
        BIO *mem = BIO_new_mem_buf(ca_pem, (int)strlen(ca_pem));
        X509_STORE *store = SSL_CTX_get_cert_store(t->ctx);
        int count = 0;
        if (mem && store) {
            X509 *ca;
            while ((ca = PEM_read_bio_X509(mem, NULL, NULL, NULL)) != NULL) {
                if (X509_STORE_add_cert(store, ca) != 1) {
                    X509_free(ca);
                    break;
                }
                count++;
                X509_free(ca);
            }
        }
        BIO_free(mem);
        ERR_clear_error(); /* PEM_read_bio_X509 signals EOF via the error queue */
        if (count == 0) {
            capture_error(t->errbuf, sizeof(t->errbuf));
            SSL_CTX_free(t->ctx);
            free(t);
            return NULL;
        }
    }

    SSL_CTX_set_verify(t->ctx, SSL_VERIFY_PEER, NULL);

    if (cert_pem[0] && key_pem[0]) {
        BIO *cert_bio = BIO_new_mem_buf(cert_pem, (int)strlen(cert_pem));
        BIO *key_bio = BIO_new_mem_buf(key_pem, (int)strlen(key_pem));
        X509 *cert = PEM_read_bio_X509(cert_bio, NULL, NULL, NULL);
        EVP_PKEY *key = PEM_read_bio_PrivateKey(key_bio, NULL, NULL, NULL);
        BIO_free(cert_bio);
        BIO_free(key_bio);
        if (!cert || !key) {
            X509_free(cert);
            EVP_PKEY_free(key);
            capture_error(t->errbuf, sizeof(t->errbuf));
            SSL_CTX_free(t->ctx);
            free(t);
            return NULL;
        }
        if (SSL_CTX_use_certificate(t->ctx, cert) != 1 ||
            SSL_CTX_use_PrivateKey(t->ctx, key) != 1 ||
            SSL_CTX_check_private_key(t->ctx) != 1) {
            X509_free(cert);
            EVP_PKEY_free(key);
            capture_error(t->errbuf, sizeof(t->errbuf));
            SSL_CTX_free(t->ctx);
            free(t);
            return NULL;
        }
        X509_free(cert);
        EVP_PKEY_free(key);
    }

    return t;
}

const char *
ovpn_tls_ctx_error(const ovpn_tls_ctx *t)
{
    return t ? t->errbuf : "null context";
}

void
ovpn_tls_ctx_free(ovpn_tls_ctx *t)
{
    if (t) {
        SSL_CTX_free(t->ctx);
        free(t);
    }
}

ovpn_tls_conn *
ovpn_tls_conn_new(ovpn_tls_ctx *t)
{
    if (!t) {
        return NULL;
    }
    ovpn_tls_conn *c = calloc(1, sizeof(ovpn_tls_conn));
    if (!c) {
        return NULL;
    }
    c->parent = t;
    c->ssl = SSL_new(t->ctx);
    if (!c->ssl) {
        capture_error(c->errbuf, sizeof(c->errbuf));
        free(c);
        return NULL;
    }
    c->rbio = BIO_new(BIO_s_mem());
    c->wbio = BIO_new(BIO_s_mem());
    if (!c->rbio || !c->wbio) {
        capture_error(c->errbuf, sizeof(c->errbuf));
        ovpn_tls_conn_free(c);
        return NULL;
    }
    SSL_set_bio(c->ssl, c->rbio, c->wbio);
    SSL_set_connect_state(c->ssl);
    return c;
}

const char *
ovpn_tls_conn_error(const ovpn_tls_conn *c)
{
    return c ? c->errbuf : "null connection";
}

void
ovpn_tls_conn_free(ovpn_tls_conn *c)
{
    if (c) {
        SSL_free(c->ssl); /* also frees the BIOs */
        free(c);
    }
}

ovpn_tls_status
ovpn_tls_handshake(ovpn_tls_conn *c)
{
    if (!c) {
        return OVPN_TLS_FAILED;
    }
    int rc = SSL_do_handshake(c->ssl);
    if (rc == 1) {
        return OVPN_TLS_OK;
    }
    int err = SSL_get_error(c->ssl, rc);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
        return err == SSL_ERROR_WANT_READ ? OVPN_TLS_WANT_READ : OVPN_TLS_WANT_WRITE;
    }
    capture_error(c->errbuf, sizeof(c->errbuf));
    return OVPN_TLS_FAILED;
}

int
ovpn_tls_is_handshaken(ovpn_tls_conn *c)
{
    return c && SSL_is_init_finished(c->ssl);
}

/* plaintext in */
int
ovpn_tls_write(ovpn_tls_conn *c, const uint8_t *data, size_t len)
{
    if (!c) {
        return -1;
    }
    int rc = SSL_write(c->ssl, data, (int)len);
    if (rc <= 0) {
        int err = SSL_get_error(c->ssl, rc);
        if (err != SSL_ERROR_WANT_READ && err != SSL_ERROR_WANT_WRITE) {
            capture_error(c->errbuf, sizeof(c->errbuf));
        }
        return -1;
    }
    return rc;
}

/* plaintext out; returns >0 bytes, 0 if no complete record, -1 on error */
int
ovpn_tls_read(ovpn_tls_conn *c, uint8_t *out, size_t cap)
{
    if (!c) {
        return -1;
    }
    int rc = SSL_read(c->ssl, out, (int)cap);
    if (rc > 0) {
        return rc;
    }
    int err = SSL_get_error(c->ssl, rc);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
        return 0;
    }
    if (err == SSL_ERROR_ZERO_RETURN) {
        return 0;
    }
    capture_error(c->errbuf, sizeof(c->errbuf));
    return -1;
}

/* ciphertext pending in the write BIO */
int
ovpn_tls_out_pending(ovpn_tls_conn *c)
{
    if (!c) {
        return 0;
    }
    return (int)BIO_ctrl_pending(c->wbio);
}

/* drain ciphertext from the write BIO */
int
ovpn_tls_drain(ovpn_tls_conn *c, uint8_t *out, size_t cap)
{
    if (!c) {
        return -1;
    }
    return (int)BIO_read(c->wbio, out, (int)cap);
}

/* feed received ciphertext into the read BIO */
void
ovpn_tls_feed(ovpn_tls_conn *c, const uint8_t *data, size_t len)
{
    if (c && len > 0) {
        BIO_write(c->rbio, data, (int)len);
    }
}

int
ovpn_tls_export_key(ovpn_tls_conn *c, const char *label, uint8_t *out, size_t len)
{
    if (!c) {
        return 0;
    }
    return SSL_export_keying_material(c->ssl, out, len, label, strlen(label),
                                      NULL, 0, 0) == 1;
}

int
ovpn_tls_get_server_cert_subject(ovpn_tls_conn *c, char *out, size_t cap)
{
    if (!c || !out || cap == 0) {
        return 0;
    }
    X509 *cert = SSL_get_peer_certificate(c->ssl);
    if (!cert) {
        return 0;
    }
    char *line = X509_NAME_oneline(X509_get_subject_name(cert), out, (int)cap);
    X509_free(cert);
    return line != NULL;
}

/* True when the certificate carries an EKU with the given dotted OID. */
static int
cert_has_eku(X509 *cert, const char *oid)
{
    EXTENDED_KEY_USAGE *eku = X509_get_ext_d2i(cert, NID_ext_key_usage, NULL, NULL);
    if (!eku) {
        return 0;
    }
    int found = 0;
    char buf[80];
    const int count = sk_ASN1_OBJECT_num(eku);
    for (int i = 0; i < count; i++) {
        OBJ_obj2txt(buf, sizeof(buf), sk_ASN1_OBJECT_value(eku, i), 1);
        if (strcmp(buf, oid) == 0) {
            found = 1;
            break;
        }
    }
    sk_ASN1_OBJECT_pop_free(eku, ASN1_OBJECT_free);
    return found;
}

int
ovpn_tls_verify_peer(ovpn_tls_conn *c, int require_server_eku,
                     int name_kind, const char *name)
{
    if (!c) {
        return 0;
    }
    X509 *cert = SSL_get_peer_certificate(c->ssl);
    if (!cert) {
        snprintf(c->errbuf, sizeof(c->errbuf), "no peer certificate presented");
        return 0;
    }
    int ok = 0;

    /* remote-cert-tls server: the certificate must be valid for TLS
     * server use (OpenVPN requires the serverAuth EKU to be present). */
    if (require_server_eku &&
        !cert_has_eku(cert, "1.3.6.1.5.5.7.3.1")) {
        snprintf(c->errbuf, sizeof(c->errbuf),
                 "certificate lacks the serverAuth EKU (remote-cert-tls server)");
        goto out;
    }

    /* verify-x509-name */
    if (name && name[0]) {
        if (name_kind == OVPN_X509_SUBJECT) {
            char subj[1024];
            BIO *bio = BIO_new(BIO_s_mem());
            if (!bio) {
                snprintf(c->errbuf, sizeof(c->errbuf), "out of memory");
                goto out;
            }
            X509_NAME_print_ex(bio, X509_get_subject_name(cert), 0, XN_FLAG_RFC2253);
            int len = BIO_read(bio, subj, (int)sizeof(subj) - 1);
            BIO_free(bio);
            if (len <= 0) {
                snprintf(c->errbuf, sizeof(c->errbuf), "cannot render certificate subject");
                goto out;
            }
            subj[len] = '\0';
            if (strcmp(subj, name) != 0) {
                snprintf(c->errbuf, sizeof(c->errbuf),
                         "subject mismatch: got '%s', want '%s'", subj, name);
                goto out;
            }
        } else {
            char cn[256];
            if (X509_NAME_get_text_by_NID(X509_get_subject_name(cert),
                                          NID_commonName, cn, sizeof(cn)) < 0) {
                snprintf(c->errbuf, sizeof(c->errbuf), "certificate has no commonName");
                goto out;
            }
            if (name_kind == OVPN_X509_NAME_PREFIX) {
                if (strncmp(cn, name, strlen(name)) != 0) {
                    snprintf(c->errbuf, sizeof(c->errbuf),
                             "commonName '%s' does not start with '%s'", cn, name);
                    goto out;
                }
            } else if (strcmp(cn, name) != 0) {
                snprintf(c->errbuf, sizeof(c->errbuf),
                         "commonName mismatch: got '%s', want '%s'", cn, name);
                goto out;
            }
        }
    }

    ok = 1;
out:
    X509_free(cert);
    return ok;
}
