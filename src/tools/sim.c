/* Runs the app on the host with scripted input, saving every screen as a PGM.
 * Point YB_API_BASE and YB_OAUTH_BASE at a mock server to use it offline.
 *
 * Usage: yb-sim <out-dir> <data-dir> <ui-font> <book-font> [step...]
 * Steps: X,Y (tap), left, right (swipes), wake, wait=FILE (blocks until FILE
 * exists, so a test can read the screen meanwhile). Ends with quit. */
#include "app/app.h"
#include "platform/net.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    const char *out_dir;
    char **steps;
    int count, next, frame;
} sim;

static int sim_present(void *ctx, const yb_canvas *c, int full) {
    sim *s = ctx;
    char path[1024];
    snprintf(path, sizeof(path), "%s/%03d.pgm", s->out_dir, s->frame++);
    printf("frame %s full=%d\n", path, full);
    fflush(stdout);
    return yb_canvas_save_pgm(c, path);
}

static void sim_wait(void *ctx, int timeout_ms, yb_event *out) {
    (void)timeout_ms;
    sim *s = ctx;
    memset(out, 0, sizeof(*out));
    if (s->next >= s->count) {
        out->type = YB_EV_QUIT;
        return;
    }
    const char *step = s->steps[s->next++];
    printf("step %s\n", step);
    fflush(stdout);
    while (strncmp(step, "wait=", 5) == 0) {
        while (access(step + 5, F_OK) != 0) usleep(100000);
        if (s->next >= s->count) {
            out->type = YB_EV_QUIT;
            return;
        }
        step = s->steps[s->next++];
    }
    if (strcmp(step, "left") == 0) out->type = YB_EV_SWIPE_LEFT;
    else if (strcmp(step, "right") == 0) out->type = YB_EV_SWIPE_RIGHT;
    else if (strcmp(step, "wake") == 0) out->type = YB_EV_WAKE;
    else if (sscanf(step, "%d,%d", &out->x, &out->y) == 2) out->type = YB_EV_TAP;
    else out->type = YB_EV_QUIT;
}

static void sim_keep_awake(void *ctx) { (void)ctx; }
static int sim_network(void *ctx) { (void)ctx; return 0; }

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <out-dir> <data-dir> <ui-font> <book-font> [step...]\n", argv[0]);
        return 2;
    }
    sim s = { .out_dir = argv[1], .steps = argv + 5, .count = argc - 5 };
    yb_host host = {
        .ctx = &s,
        .present = sim_present,
        .wait_event = sim_wait,
        .keep_awake = sim_keep_awake,
        .ensure_network = sim_network,
    };
    yb_app_paths paths = { .data_dir = argv[2], .ui_font = argv[3], .book_font = argv[4] };
    yb_canvas *c = yb_canvas_new(1236, 1648, 300);
    yb_net_global_init();
    int rc = yb_app_run(&host, c, &paths);
    yb_net_global_cleanup();
    yb_canvas_free(c);
    return rc;
}
