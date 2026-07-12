#include "test_util.h"

#include "util/base64.h"
#include "yandex/crypto.h"

#include <stdlib.h>
#include <string.h>

/* Fixed AES-256-CBC vector (IV-prefixed, PKCS7) generated with pycryptodome,
 * matching the Bookmate manifest scheme confirmed in Phase 0. */
static const char *KEY_B64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";
static const unsigned char DATA[] = {
    16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
    64,234,51,77,129,121,21,76,176,163,254,132,49,246,129,71,
    32,57,88,139,151,81,137,154,43,118,66,91,131,149,44,160,
    216,93,80,99,238,82,102,178,20,158,19,177,189,50,65,240,
    176,183,253,237,139,132,116,189,39,130,212,227,213,163,43,252,
};
static const char *EXPECT = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><package/>";

int main(void) {
    size_t klen = 0;
    unsigned char *key = yb_base64_decode(KEY_B64, &klen);
    CHECK(key != NULL);
    CHECK(klen == 32);

    size_t out_len = 0;
    unsigned char *pt = NULL;
    if (key && klen == 32)
        pt = yb_aes256_cbc_decrypt_ivprefix(key, DATA, sizeof(DATA), &out_len);

    CHECK(pt != NULL);
    if (pt) {
        CHECK(out_len == strlen(EXPECT));
        CHECK_STR((char *)pt, EXPECT);
    }
    free(pt);
    free(key);

    if (tests_failed == 0) printf("test_crypto: OK\n");
    return tests_failed != 0;
}
