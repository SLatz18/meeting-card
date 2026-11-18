#ifndef LM_HARNESS_TLS_SHIM_H
#define LM_HARNESS_TLS_SHIM_H

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/sha.h>
#include <openssl/rand.h>

// OpenSSL exposes these as macros, which Swift can't import.

static inline long lm_tls_set_sni(SSL *ssl, const char *host) {
    return SSL_set_tlsext_host_name(ssl, host);
}

static inline long lm_tls_set_partial_writes(SSL *ssl) {
    return SSL_set_mode(ssl, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
}

static inline long lm_tls_min_tls12(SSL_CTX *ctx) {
    return SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
}

#endif
