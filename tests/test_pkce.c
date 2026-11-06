#include "test_util.h"

#include "yandex/auth.h"

#include <stdlib.h>

int main(void) {
    /* The worked example from RFC 7636, appendix B. */
    char challenge[64];
    CHECK(yb_pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", challenge) == 0);
    CHECK_STR(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");

    char a[YB_PKCE_VERIFIER_LEN + 1], b[YB_PKCE_VERIFIER_LEN + 1];
    CHECK(yb_pkce_new_verifier(a) == 0);
    CHECK(yb_pkce_new_verifier(b) == 0);
    CHECK(strlen(a) == YB_PKCE_VERIFIER_LEN);
    CHECK(strcmp(a, b) != 0);

    char *url = yb_auth_pkce_url("abc", "xyz");
    CHECK(url != NULL);
    CHECK(url && strstr(url, "client_id=abc") != NULL);
    CHECK(url && strstr(url, "code_challenge=xyz") != NULL);
    CHECK(url && strstr(url, "code_challenge_method=S256") != NULL);
    free(url);

    if (!tests_failed) printf("test_pkce: OK\n");
    return tests_failed != 0;
}
