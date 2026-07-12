/* Host smoke tool: exercises the real network + API path end-to-end without
 * any Kindle hardware. It performs the OAuth device flow (or reuses a saved
 * token), then lists the authenticated user's library.
 *
 * This is the runnable proof of tracks B/C from docs/PHASE0.md at the code
 * level. Content/reader are intentionally not exercised (Phase 0 blocked).
 *
 * Env:
 *   YANDEX_CLIENT_ID      OAuth client id (required for device flow)
 *   YANDEX_CLIENT_SECRET  OAuth client secret (if the client is confidential)
 *   YANDEX_TOKEN          skip device flow and use this token directly
 *   YB_API_BASE           override the Books API base URL (Phase 0)
 *   YB_CA_BUNDLE          path to a CA bundle (device build)
 */
#include "platform/net.h"
#include "storage/config.h"
#include "yandex/api.h"
#include "yandex/auth.h"
#include "yandex/models.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void usage(const char *argv0) {
    printf(
        "Usage: %s [command]\n"
        "\n"
        "Commands:\n"
        "  login     run the OAuth device flow and save the token (default if\n"
        "            no token is available)\n"
        "  library   list the authenticated user's library\n"
        "  whoami    validate the current token\n"
        "\n"
        "Configuration comes from env vars (see source header) and the config\n"
        "file (YB_CONFIG, else ~/.config/kindle-yaknigi/config).\n",
        argv0);
}

/* Resolve a usable token: env override wins, else config. Returns malloc'd
 * string or NULL. */
static char *resolve_token(yb_config *cfg) {
    const char *env = getenv("YANDEX_TOKEN");
    if (env && *env) return strdup(env);
    const char *saved = yb_config_get(cfg, "token");
    if (saved && *saved) return strdup(saved);
    return NULL;
}

static int do_login(yb_config *cfg) {
    const char *client_id = getenv("YANDEX_CLIENT_ID");
    const char *client_secret = getenv("YANDEX_CLIENT_SECRET");
    if (!client_id || !*client_id) {
        fprintf(stderr, "error: YANDEX_CLIENT_ID is required for login\n");
        return 2;
    }

    yb_device_code dc;
    if (yb_auth_request_device_code(client_id, client_secret,
                                    yb_config_device_id(cfg),
                                    "Kindle (kindle-yaknigi)", &dc) != 0) {
        fprintf(stderr, "error: could not start device flow\n");
        return 1;
    }

    printf("\n  Open:  %s\n  Code:  %s\n\n",
           dc.verification_url ? dc.verification_url : "https://ya.ru/device",
           dc.user_code);
    printf("Waiting for confirmation (expires in %ds)...\n", dc.expires_in);

    int interval = dc.interval > 0 ? dc.interval : 5;
    time_t deadline = time(NULL) + (dc.expires_in > 0 ? dc.expires_in : 600);
    int rc = 1;
    char *token = NULL;
    while (time(NULL) < deadline) {
        sleep((unsigned)interval);
        yb_auth_status st = yb_auth_poll_token(client_id, client_secret,
                                               dc.device_code, &token);
        if (st == YB_AUTH_OK) {
            yb_config_set(cfg, "token", token);
            yb_config_save(cfg);
            free(token);
            printf("Logged in. Token saved.\n");
            rc = 0;
            break;
        } else if (st == YB_AUTH_SLOW_DOWN) {
            interval += 2;
        } else if (st == YB_AUTH_PENDING) {
            /* keep waiting */
        } else {
            fprintf(stderr, "error: authorization failed\n");
            break;
        }
    }
    if (rc != 0 && time(NULL) >= deadline)
        fprintf(stderr, "error: device code expired before confirmation\n");
    yb_device_code_free(&dc);
    return rc;
}

static int do_whoami(const char *token) {
    int v = yb_auth_test_token(token);
    if (v < 0) { fprintf(stderr, "error: could not reach Yandex\n"); return 1; }
    printf(v ? "token: valid\n" : "token: invalid\n");
    return v ? 0 : 1;
}

static int do_library(const char *token) {
    yb_library lib;
    int rc = yb_api_get_my_library(token, &lib);
    if (rc == 401) { fprintf(stderr, "error: unauthorized (bad/expired token)\n"); return 1; }
    if (rc != 0) { fprintf(stderr, "error: could not fetch library (rc=%d)\n", rc); return 1; }

    printf("Library: %zu book(s)\n", lib.count);
    for (size_t i = 0; i < lib.count; ++i) {
        yb_book *b = &lib.items[i].book;
        printf("  [%3d%%] %-40s %s\n",
               lib.items[i].progress,
               b->title ? b->title : "(untitled)",
               b->author_count && b->authors[0].name ? b->authors[0].name : "");
    }
    yb_library_free(&lib);
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        usage(argv[0]);
        return 0;
    }

    yb_net_global_init();
    yb_config *cfg = yb_config_open();
    int rc = 0;

    const char *cmd = argc > 1 ? argv[1] : NULL;
    char *token = resolve_token(cfg);

    if (cmd && strcmp(cmd, "login") == 0) {
        rc = do_login(cfg);
    } else if (!token && (!cmd || strcmp(cmd, "library") == 0 || strcmp(cmd, "whoami") == 0)) {
        fprintf(stderr, "No token found; running login first.\n");
        rc = do_login(cfg);
        free(token);
        token = resolve_token(cfg);
    }

    if (rc == 0 && token) {
        if (!cmd || strcmp(cmd, "library") == 0) rc = do_library(token);
        else if (strcmp(cmd, "whoami") == 0) rc = do_whoami(token);
        else if (strcmp(cmd, "login") != 0) { usage(argv[0]); rc = 2; }
    }

    free(token);
    yb_config_free(cfg);
    yb_net_global_cleanup();
    return rc;
}
