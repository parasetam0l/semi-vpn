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

/* Supplies the configured key passphrase; with none, fails instead of
 * letting OpenSSL prompt on a terminal (which would block or fail inside a
 * Network Extension). */
static int
password_cb(char *buf, int size, int rwflag, void *userdata)
{
    (void)rwflag;
    const char *password = userdata;
    if (!password || !buf || size <= 0)
    {
        return 0;
    }
    int len = (int)strlen(password);
    if (len > size)
    {
        len = size;
    }
    memcpy(buf, password, (size_t)len);
    return len;
}

static void set_error(char *err, size_t err_len, const char *prefix)
{
    if (!err || err_len == 0)
    {
        return;
    }
    char detail[200];
    capture_error(detail, sizeof(detail));
    snprintf(err, err_len, "%s: %s", prefix, detail);
}

/* Appends `len` bytes of `text` to `out` (capacity `cap`, `*used` bytes so
 * far), after a ':' unless it is the first entry. */
static void
append_cipher(char *out, size_t cap, size_t *used, const char *text, size_t len)
{
    if (*used > 0 && *used + 1 < cap)
    {
        out[(*used)++] = ':';
    }
    if (*used + len >= cap)
    {
        len = cap - *used - 1;
    }
    memcpy(out + *used, text, len);
    *used += len;
    out[*used] = '\0';
}

/*
 * tls-cipher the way OpenVPN reads it: a ':'-separated TLS 1.2 list whose
 * IANA names ("TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256", the form OpenVPN
 * documents and openvpn-install writes) become OpenSSL names
 * ("ECDHE-ECDSA-AES128-GCM-SHA256"). OpenSSL knows the standard name of
 * every suite it supports, so no table is needed. Other entries (OpenSSL
 * names, keywords such as DEFAULT or !aNULL) pass through unchanged.
 * Returns a malloc'ed string, or NULL when out of memory.
 */
static char *
openssl_cipher_list(const char *list)
{
    size_t entries = 1;
    for (const char *p = list; *p; p++)
    {
        entries += *p == ':';
    }
    /* OpenSSL names are shorter than 64 characters. */
    size_t cap = strlen(list) + entries * 64 + 1;
    char *out = calloc(1, cap);
    if (!out)
    {
        return NULL;
    }
    size_t used = 0;
    const char *entry = list;
    for (;;)
    {
        size_t len = strcspn(entry, ":");
        const char *name = NULL;
        char standard[128];
        if (len > 4 && len < sizeof(standard) && strncmp(entry, "TLS-", 4) == 0)
        {
            /* IANA names use '_' where OpenVPN's use '-'. */
            for (size_t i = 0; i < len; i++)
            {
                standard[i] = entry[i] == '-' ? '_' : entry[i];
            }
            standard[len] = '\0';
            const char *found = OPENSSL_cipher_name(standard);
            if (found && strcmp(found, "(NONE)") != 0)
            {
                name = found;
            }
        }
        if (name)
        {
            append_cipher(out, cap, &used, name, strlen(name));
        }
        else if (len > 0)
        {
            append_cipher(out, cap, &used, entry, len);
        }
        if (entry[len] == '\0')
        {
            break;
        }
        entry += len + 1;
    }
    return out;
}

/* tls-ciphersuites (TLS 1.3): OpenVPN also accepts '-' for OpenSSL's '_'
 * ("TLS-AES-256-GCM-SHA384"). Returns a malloc'ed string, or NULL. */
static char *
openssl_ciphersuites(const char *list)
{
    char *out = strdup(list);
    if (out)
    {
        for (char *p = out; *p; p++)
        {
            if (*p == '-')
            {
                *p = '_';
            }
        }
    }
    return out;
}

/* Adds every certificate of a PEM bundle to the context's chain. */
static int
add_chain_certs(SSL_CTX *ctx, BIO *bio)
{
    X509 *cert;
    while ((cert = PEM_read_bio_X509(bio, NULL, NULL, NULL)) != NULL)
    {
        if (SSL_CTX_add0_chain_cert(ctx, cert) != 1)
        {
            X509_free(cert);
            return 0;
        }
    }
    ERR_clear_error(); /* EOF is reported through the error queue */
    return 1;
}

ovpn_tls_ctx *
ovpn_tls_ctx_new(const ovpn_tls_config *config, char *err, size_t err_len)
{
    if (err && err_len)
    {
        err[0] = '\0';
    }
    if (!config || !config->ca_pem)
    {
        if (err && err_len)
        {
            snprintf(err, err_len, "no CA certificate");
        }
        return NULL;
    }

    ovpn_tls_ctx *t = calloc(1, sizeof(ovpn_tls_ctx));
    if (!t)
    {
        return NULL;
    }

    t->ctx = SSL_CTX_new(TLS_client_method());
    if (!t->ctx)
    {
        set_error(err, err_len, "SSL_CTX_new");
        free(t);
        return NULL;
    }

    /* Control channel: TLS 1.2 minimum (OpenVPN's default); TLS 1.3
     * preferred when the server supports it. tls-version-min may only
     * raise the floor. */
    int min_version = config->min_version > TLS1_2_VERSION ? config->min_version : TLS1_2_VERSION;
    SSL_CTX_set_min_proto_version(t->ctx, min_version);
    SSL_CTX_set_max_proto_version(t->ctx, TLS1_3_VERSION);

    if (config->cipher_list && config->cipher_list[0])
    {
        char *list = openssl_cipher_list(config->cipher_list);
        int ok = list && SSL_CTX_set_cipher_list(t->ctx, list) == 1;
        free(list);
        if (!ok)
        {
            ERR_clear_error();
            if (err && err_len)
            {
                snprintf(err, err_len, "tls-cipher: none of \"%s\" is a cipher this version supports",
                         config->cipher_list);
            }
            goto fail;
        }
    }
    if (config->ciphersuites && config->ciphersuites[0])
    {
        char *suites = openssl_ciphersuites(config->ciphersuites);
        int ok = suites && SSL_CTX_set_ciphersuites(t->ctx, suites) == 1;
        free(suites);
        if (!ok)
        {
            ERR_clear_error();
            if (err && err_len)
            {
                snprintf(err, err_len, "tls-ciphersuites: none of \"%s\" is a TLS 1.3 suite this version supports",
                         config->ciphersuites);
            }
            goto fail;
        }
    }

    /* NSS key log for debugging the TLS stream */
    SSL_CTX_set_keylog_callback(t->ctx, keylog_cb);

    /* Load every PEM certificate in the CA block (profiles may carry
     * intermediate chains, not just the root). */
    {
        BIO *mem = BIO_new_mem_buf(config->ca_pem, (int)strlen(config->ca_pem));
        X509_STORE *store = SSL_CTX_get_cert_store(t->ctx);
        int count = 0;
        if (mem && store)
        {
            X509 *ca;
            while ((ca = PEM_read_bio_X509(mem, NULL, NULL, NULL)) != NULL)
            {
                if (X509_STORE_add_cert(store, ca) == 1)
                {
                    count++;
                }
                X509_free(ca);
            }
        }
        BIO_free(mem);
        ERR_clear_error(); /* PEM_read_bio_X509 signals EOF via the error queue */
        if (count == 0)
        {
            if (err && err_len)
            {
                snprintf(err, err_len, "the CA block contains no valid certificate");
            }
            goto fail;
        }
    }

    SSL_CTX_set_verify(t->ctx, SSL_VERIFY_PEER, NULL);

    const char *cert_pem = config->cert_pem;
    const char *key_pem = config->key_pem;
    if (cert_pem && cert_pem[0] && key_pem && key_pem[0])
    {
        BIO *cert_bio = BIO_new_mem_buf(cert_pem, (int)strlen(cert_pem));
        X509 *cert = PEM_read_bio_X509(cert_bio, NULL, NULL, NULL);
        if (!cert)
        {
            BIO_free(cert_bio);
            set_error(err, err_len, "client certificate");
            goto fail;
        }
        if (SSL_CTX_use_certificate(t->ctx, cert) != 1)
        {
            X509_free(cert);
            BIO_free(cert_bio);
            set_error(err, err_len, "client certificate");
            goto fail;
        }
        X509_free(cert);
        /* Certificates after the leaf form its chain. */
        int chain_ok = add_chain_certs(t->ctx, cert_bio);
        BIO_free(cert_bio);
        if (!chain_ok)
        {
            set_error(err, err_len, "client certificate chain");
            goto fail;
        }

        if (config->extra_certs_pem && config->extra_certs_pem[0])
        {
            BIO *extra_bio = BIO_new_mem_buf(config->extra_certs_pem,
                                             (int)strlen(config->extra_certs_pem));
            int extra_ok = add_chain_certs(t->ctx, extra_bio);
            BIO_free(extra_bio);
            if (!extra_ok)
            {
                set_error(err, err_len, "extra-certs");
                goto fail;
            }
        }

        BIO *key_bio = BIO_new_mem_buf(key_pem, (int)strlen(key_pem));
        EVP_PKEY *key = PEM_read_bio_PrivateKey(key_bio, NULL, password_cb,
                                                (void *)config->key_password);
        BIO_free(key_bio);
        if (!key)
        {
            set_error(err, err_len, config->key_password
                      ? "private key (wrong passphrase?)"
                      : "private key (encrypted keys need a passphrase)");
            goto fail;
        }
        int key_ok = SSL_CTX_use_PrivateKey(t->ctx, key) == 1
                     && SSL_CTX_check_private_key(t->ctx) == 1;
        EVP_PKEY_free(key);
        if (!key_ok)
        {
            set_error(err, err_len, "private key does not match the certificate");
            goto fail;
        }
    }

    return t;

fail:
    SSL_CTX_free(t->ctx);
    free(t);
    return NULL;
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
    /* Prefer the readable library reason; add the certificate verification
     * result when that is what failed. */
    unsigned long code = ERR_peek_last_error();
    const char *reason = code ? ERR_reason_error_string(code) : NULL;
    long verify = SSL_get_verify_result(c->ssl);
    if (verify != X509_V_OK) {
        snprintf(c->errbuf, sizeof(c->errbuf), "%s (%s)",
                 reason ? reason : "certificate verify failed",
                 X509_verify_cert_error_string(verify));
    } else if (reason) {
        snprintf(c->errbuf, sizeof(c->errbuf), "%s", reason);
    } else {
        capture_error(c->errbuf, sizeof(c->errbuf));
    }
    ERR_clear_error();
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
    if (require_server_eku)
    {
        /* remote-cert-tls server = remote-cert-ku (a key usage extension
         * must be present) + remote-cert-eku serverAuth, as in OpenVPN. */
        if (!(X509_get_extension_flags(cert) & EXFLAG_KUSAGE))
        {
            snprintf(c->errbuf, sizeof(c->errbuf),
                     "certificate has no key usage extension (remote-cert-tls server)");
            goto out;
        }
        if (!cert_has_eku(cert, "1.3.6.1.5.5.7.3.1"))
        {
            snprintf(c->errbuf, sizeof(c->errbuf),
                     "certificate lacks the serverAuth EKU (remote-cert-tls server)");
            goto out;
        }
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
            /* The same rendering OpenVPN's x509_get_subject() uses:
             * "C=US, O=Example, CN=server". */
            X509_NAME_print_ex(bio, X509_get_subject_name(cert), 0,
                               XN_FLAG_SEP_CPLUS_SPC | XN_FLAG_FN_SN | ASN1_STRFLGS_UTF8_CONVERT);
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
