#ifndef YB_YANDEX_AUTH_H
#define YB_YANDEX_AUTH_H

/* OAuth 2.0 Device Authorization Grant for Yandex ID (see PLAN.md 6 and
 * docs/PHASE0.md track C). Lets an e-ink Kindle authenticate without a
 * browser or keyboard: the device shows a short user_code + URL/QR, the user
 * confirms on a phone, and we poll for the token.
 *
 * Endpoints (Yandex): POST https://oauth.yandex.ru/device/code
 *                     POST https://oauth.yandex.ru/token
 */

typedef struct {
    char *device_code;      /* opaque; used when polling for the token */
    char *user_code;        /* short code the user types on the phone */
    char *verification_url; /* page the user opens to confirm */
    int   interval;         /* seconds to wait between polls */
    int   expires_in;       /* lifetime of the codes, seconds */
} yb_device_code;

void yb_device_code_free(yb_device_code *dc);

/* Request a device_code/user_code pair. `client_secret` may be NULL for a
 * public client. Returns 0 on success. */
int yb_auth_request_device_code(const char *client_id,
                                const char *client_secret,
                                const char *device_id,
                                const char *device_name,
                                yb_device_code *out);

typedef enum {
    YB_AUTH_OK = 0,       /* token obtained */
    YB_AUTH_PENDING = 1,  /* user hasn't confirmed yet (keep polling) */
    YB_AUTH_SLOW_DOWN = 2,/* poll less frequently */
    YB_AUTH_DENIED = 3,   /* user denied / code expired / other terminal error */
    YB_AUTH_ERROR = -1,   /* transport or parse failure */
} yb_auth_status;

/* Poll once for the token. On YB_AUTH_OK, *token_out is set to a malloc'd
 * access token the caller owns. */
yb_auth_status yb_auth_poll_token(const char *client_id,
                                  const char *client_secret,
                                  const char *device_code,
                                  char **token_out);

/* Validate a token by calling the account info endpoint. Returns 1 if valid,
 * 0 if rejected, -1 on transport error. */
int yb_auth_test_token(const char *token);

#endif /* YB_YANDEX_AUTH_H */
