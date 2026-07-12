#include "yandex/crypto.h"

#include "util/log.h"

#include <openssl/evp.h>
#include <stdlib.h>
#include <string.h>

unsigned char *yb_aes256_cbc_decrypt_ivprefix(const unsigned char key[32],
                                              const unsigned char *data,
                                              size_t data_len,
                                              size_t *out_len) {
    if (data_len < 32 || (data_len % 16) != 0) {
        YB_ERR("aes: bad ciphertext length %zu", data_len);
        return NULL;
    }
    const unsigned char *iv = data;
    const unsigned char *ct = data + 16;
    int ct_len = (int)(data_len - 16);

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return NULL;

    unsigned char *out = malloc((size_t)ct_len + 16); /* room for block */
    if (!out) { EVP_CIPHER_CTX_free(ctx); return NULL; }

    int ok = 0, outl = 0, total = 0;
    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, key, iv) == 1 &&
        EVP_DecryptUpdate(ctx, out, &outl, ct, ct_len) == 1) {
        total = outl;
        if (EVP_DecryptFinal_ex(ctx, out + total, &outl) == 1) {
            total += outl;               /* PKCS7 padding stripped by OpenSSL */
            ok = 1;
        }
    }
    EVP_CIPHER_CTX_free(ctx);

    if (!ok) {
        YB_ERR("aes: decrypt/padding failed");
        free(out);
        return NULL;
    }
    out[total] = '\0';
    if (out_len) *out_len = (size_t)total;
    return out;
}
