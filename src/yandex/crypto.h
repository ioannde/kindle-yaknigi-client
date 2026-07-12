#ifndef YB_YANDEX_CRYPTO_H
#define YB_YANDEX_CRYPTO_H

#include <stddef.h>

/* AES-256-CBC decryption for the Bookmate metadata manifest (see
 * docs/PHASE0-FINDINGS.md): the opf/ncx/container blobs are AES-256-CBC with
 * the IV prepended as the first 16 bytes and PKCS7 padding; the key is the
 * base64-decoded /metadata_secret value (32 bytes).
 *
 * `data` is the full blob (IV || ciphertext). Returns a malloc'd plaintext
 * buffer (NUL-terminated one past *out_len) or NULL on error. */
unsigned char *yb_aes256_cbc_decrypt_ivprefix(const unsigned char key[32],
                                              const unsigned char *data,
                                              size_t data_len,
                                              size_t *out_len);

#endif /* YB_YANDEX_CRYPTO_H */
