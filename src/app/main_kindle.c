/* Kindle entry point: connects the app to FBInk, the touchscreen and the
 * system's power and Wi-Fi services. Started by kual/yaknigi/run.sh, which
 * pauses the Kindle UI around this process and restores it afterwards. */
#include "app/app.h"
#include "platform/display_fbink.h"
#include "platform/input_evdev.h"
#include "platform/net.h"
#include "util/log.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define KEEP_AWAKE_EVERY_S 30
#define WIFI_WAIT_S 30

typedef struct {
    yb_display *display;
    yb_touch *touch;
    int power_fd;
    int asleep;
    char power_line[256];
    size_t power_len;
    time_t last_keep_awake;
} device;

static void spawn_quiet(const char *const argv[]) {
    pid_t pid = fork();
    if (pid != 0) return; /* SIGCHLD is ignored, so children never linger */
    int null = open("/dev/null", O_RDWR);
    if (null >= 0) {
        dup2(null, 0);
        dup2(null, 1);
        dup2(null, 2);
    }
    execvp(argv[0], (char *const *)argv);
    _exit(127);
}

/* Reports power button and sleep events on the returned fd, or -1 if the
 * listener cannot start. Without it the app works but does not repaint on wake. */
static int start_power_listener(void) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    if (pid == 0) {
        prctl(PR_SET_PDEATHSIG, SIGTERM);
        dup2(fds[1], 1);
        close(fds[0]);
        close(fds[1]);
        execlp("lipc-wait-event", "lipc-wait-event", "-m", "com.lab126.powerd",
               "goingToScreenSaver,outOfScreenSaver", (char *)NULL);
        _exit(127);
    }
    close(fds[1]);
    fcntl(fds[0], F_SETFL, O_NONBLOCK);
    return fds[0];
}

/* Returns 1 if the screen needs repainting. */
static int handle_power_output(device *d) {
    char buf[128];
    ssize_t n = read(d->power_fd, buf, sizeof(buf));
    if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
        YB_WARN("power listener stopped");
        close(d->power_fd);
        d->power_fd = -1;
        return 0;
    }
    int repaint = 0;
    for (ssize_t i = 0; i < n; ++i) {
        if (buf[i] != '\n') {
            if (d->power_len + 1 < sizeof(d->power_line)) d->power_line[d->power_len++] = buf[i];
            continue;
        }
        d->power_line[d->power_len] = '\0';
        d->power_len = 0;
        if (strstr(d->power_line, "goingToScreenSaver")) {
            /* The lock screen may need the touchscreen. */
            yb_touch_set_grab(d->touch, 0);
            d->asleep = 1;
        } else if (strstr(d->power_line, "outOfScreenSaver")) {
            yb_touch_set_grab(d->touch, 1);
            d->asleep = 0;
            usleep(500000); /* let the system finish its own screen update */
            repaint = 1;
        }
    }
    return repaint;
}

static int host_present(void *ctx, const yb_canvas *c, int full) {
    device *d = ctx;
    return yb_display_present(d->display, c, full);
}

static void host_wait_event(void *ctx, int timeout_ms, yb_event *out) {
    device *d = ctx;
    memset(out, 0, sizeof(*out));
    for (;;) {
        int rx = 0, ry = 0;
        yb_touch_result r = yb_touch_wait(d->touch, d->power_fd, timeout_ms, &rx, &ry);
        switch (r) {
        case YB_TOUCH_OTHER_FD:
            if (handle_power_output(d)) {
                out->type = YB_EV_WAKE;
                return;
            }
            continue;
        case YB_TOUCH_TIMEOUT:
            out->type = YB_EV_TIMEOUT;
            return;
        case YB_TOUCH_ERROR:
            out->type = YB_EV_QUIT;
            return;
        case YB_TOUCH_TAP:
        case YB_TOUCH_SWIPE_LEFT:
        case YB_TOUCH_SWIPE_RIGHT:
            break;
        }
        if (d->asleep) continue;
        int max_x, max_y;
        yb_touch_range(d->touch, &max_x, &max_y);
        int w = yb_display_width(d->display), h = yb_display_height(d->display);
        out->type = r == YB_TOUCH_TAP ? YB_EV_TAP
                  : r == YB_TOUCH_SWIPE_LEFT ? YB_EV_SWIPE_LEFT : YB_EV_SWIPE_RIGHT;
        out->x = max_x > 0 ? rx * w / (max_x + 1) : rx;
        out->y = max_y > 0 ? ry * h / (max_y + 1) : ry;
        return;
    }
}

/* The system cannot see touches while they are grabbed, so it has to be told
 * that the device is in use or it will go to sleep in the middle of a book. */
static void host_keep_awake(void *ctx) {
    device *d = ctx;
    time_t now = time(NULL);
    if (now - d->last_keep_awake < KEEP_AWAKE_EVERY_S) return;
    d->last_keep_awake = now;
    static const char *const argv[] = {
        "lipc-set-prop", "-i", "com.lab126.powerd", "touchScreenSaverTimeout", "1", NULL,
    };
    spawn_quiet(argv);
}

static int wifi_connected(int *known) {
    FILE *p = popen("lipc-get-prop com.lab126.wifid cmState 2>/dev/null", "r");
    if (!p) { *known = 0; return 0; }
    char state[32] = "";
    int got = fgets(state, sizeof(state), p) != NULL;
    pclose(p);
    *known = got;
    return got && strncmp(state, "CONNECTED", 9) == 0;
}

static int host_ensure_network(void *ctx) {
    int known = 0;
    if (wifi_connected(&known)) return 0;
    if (!known) return 0; /* cannot tell, so let the request itself decide */

    YB_INFO("network: turning Wi-Fi on");
    static const char *const argv[] = {
        "lipc-set-prop", "-i", "com.lab126.wifid", "enable", "1", NULL,
    };
    spawn_quiet(argv);
    for (int i = 0; i < WIFI_WAIT_S; ++i) {
        sleep(1);
        host_keep_awake(ctx);
        if (wifi_connected(&known)) return 0;
    }
    YB_WARN("network: Wi-Fi did not connect");
    return -1;
}

static const char *env_or(const char *name, const char *fallback) {
    const char *v = getenv(name);
    return v && *v ? v : fallback;
}

int main(void) {
    umask(077);
    signal(SIGCHLD, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);

    device d = { .power_fd = -1 };
    d.display = yb_display_open();
    if (!d.display) return 1;
    char info[192];
    yb_display_describe(d.display, info, sizeof(info));
    YB_INFO("%s", info);

    d.touch = yb_touch_open();
    if (!d.touch) {
        yb_display_close(d.display);
        return 1;
    }
    d.power_fd = start_power_listener();

    yb_canvas *canvas = yb_canvas_new(yb_display_width(d.display), yb_display_height(d.display),
                                      yb_display_dpi(d.display));
    int rc = 1;
    if (canvas) {
        yb_net_global_init();
        yb_host host = {
            .ctx = &d,
            .present = host_present,
            .wait_event = host_wait_event,
            .keep_awake = host_keep_awake,
            .ensure_network = host_ensure_network,
        };
        yb_app_paths paths = {
            .data_dir = env_or("YB_DATA_DIR", "data"),
            .ui_font = env_or("YB_UI_FONT", "DejaVuSans.ttf"),
            .book_font = env_or("YB_BOOK_FONT", "DejaVuSerif.ttf"),
        };
        rc = yb_app_run(&host, canvas, &paths);
        yb_net_global_cleanup();
        yb_canvas_free(canvas);
    }
    yb_touch_close(d.touch);
    yb_display_close(d.display);
    return rc;
}
