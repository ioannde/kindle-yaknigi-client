#ifndef YB_APP_APP_H
#define YB_APP_APP_H

#include "platform/display.h"

/* The whole application: login, library and reader screens. It reaches the
 * device only through yb_host, so the same code runs on the Kindle and, with
 * scripted input, on the host (see tools/sim.c). */

typedef enum {
    YB_EV_TIMEOUT,
    YB_EV_TAP,
    YB_EV_SWIPE_LEFT,
    YB_EV_SWIPE_RIGHT,
    YB_EV_WAKE, /* the screen must be repainted: another program drew over it */
    YB_EV_QUIT,
} yb_event_type;

typedef struct {
    yb_event_type type;
    int x, y; /* canvas coordinates */
} yb_event;

typedef struct {
    void *ctx;
    int  (*present)(void *ctx, const yb_canvas *c, int full);
    /* timeout_ms < 0 waits indefinitely. */
    void (*wait_event)(void *ctx, int timeout_ms, yb_event *out);
    /* Called on activity, so that the device does not go to sleep mid-book. */
    void (*keep_awake)(void *ctx);
    /* Returns once the network should be usable, or -1 if it did not come up. */
    int  (*ensure_network)(void *ctx);
} yb_host;

typedef struct {
    const char *data_dir;  /* books, positions and the library list */
    const char *ui_font;
    const char *book_font;
} yb_app_paths;

/* Runs until the user exits. Returns 0, or non-zero if it could not start. */
int yb_app_run(yb_host *host, yb_canvas *canvas, const yb_app_paths *paths);

#endif /* YB_APP_APP_H */
