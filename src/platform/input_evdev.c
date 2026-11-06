#include "platform/input_evdev.h"

#include "util/log.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define BITS_PER_WORD (sizeof(unsigned long) * CHAR_BIT)
#define WORDS_FOR(n) ((n) / BITS_PER_WORD + 1)

struct yb_touch {
    int fd;
    int max_x, max_y;
    int x, y;
    int start_x, start_y;
    int need_start_x, need_start_y;
    int slot;
    int down;
};

static int has_bit(const unsigned long *bits, unsigned bit) {
    return (bits[bit / BITS_PER_WORD] >> (bit % BITS_PER_WORD)) & 1UL;
}

/* 2 = multitouch panel, 1 = older single-touch panel, 0 = not a touchscreen. */
static int touch_kind(int fd) {
    unsigned long abs_bits[WORDS_FOR(ABS_MAX)] = {0};
    unsigned long key_bits[WORDS_FOR(KEY_MAX)] = {0};
    if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs_bits)), abs_bits) < 0) return 0;
    if (has_bit(abs_bits, ABS_MT_POSITION_X) && has_bit(abs_bits, ABS_MT_POSITION_Y)) return 2;
    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(key_bits)), key_bits) < 0) return 0;
    if (has_bit(abs_bits, ABS_X) && has_bit(key_bits, BTN_TOUCH)) return 1;
    return 0;
}

yb_touch *yb_touch_open(void) {
    int best_fd = -1, best_kind = 0;
    char best_name[64] = "";

    for (int i = 0; i < 16; ++i) {
        char path[32], name[64] = "?";
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);
        int kind = touch_kind(fd);
        YB_INFO("input: %s '%s' touch_kind=%d", path, name, kind);
        if (kind > best_kind) {
            if (best_fd >= 0) close(best_fd);
            best_fd = fd;
            best_kind = kind;
            snprintf(best_name, sizeof(best_name), "%s", name);
        } else {
            close(fd);
        }
    }
    if (best_fd < 0) {
        YB_ERR("input: no touchscreen found");
        return NULL;
    }

    yb_touch *t = calloc(1, sizeof(*t));
    if (!t) { close(best_fd); return NULL; }
    t->fd = best_fd;

    struct input_absinfo ax = {0}, ay = {0};
    ioctl(best_fd, EVIOCGABS(best_kind == 2 ? ABS_MT_POSITION_X : ABS_X), &ax);
    ioctl(best_fd, EVIOCGABS(best_kind == 2 ? ABS_MT_POSITION_Y : ABS_Y), &ay);
    t->max_x = ax.maximum;
    t->max_y = ay.maximum;

    if (ioctl(best_fd, EVIOCGRAB, 1) != 0)
        YB_WARN("input: grab failed: %s", strerror(errno));
    YB_INFO("input: using '%s', range %dx%d", best_name, t->max_x, t->max_y);
    return t;
}

void yb_touch_close(yb_touch *t) {
    if (!t) return;
    ioctl(t->fd, EVIOCGRAB, 0);
    close(t->fd);
    free(t);
}

void yb_touch_range(const yb_touch *t, int *max_x, int *max_y) {
    *max_x = t->max_x;
    *max_y = t->max_y;
}

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

void yb_touch_set_grab(yb_touch *t, int grabbed) {
    if (ioctl(t->fd, EVIOCGRAB, grabbed ? 1 : 0) != 0)
        YB_WARN("input: grab change failed: %s", strerror(errno));
    t->down = 0;
    t->slot = 0;
}

static yb_touch_result lifted_gesture(const yb_touch *t) {
    int dx = t->x - t->start_x;
    int dy = t->y - t->start_y;
    int min_swipe = t->max_x / 8;
    if (abs(dx) >= min_swipe && abs(dx) > abs(dy))
        return dx < 0 ? YB_TOUCH_SWIPE_LEFT : YB_TOUCH_SWIPE_RIGHT;
    return YB_TOUCH_TAP;
}

yb_touch_result yb_touch_wait(yb_touch *t, int extra_fd, int timeout_ms, int *x, int *y) {
    long deadline = timeout_ms < 0 ? 0 : now_ms() + timeout_ms;
    for (;;) {
        struct input_event ev;
        ssize_t n = read(t->fd, &ev, sizeof(ev));
        if (n == (ssize_t)sizeof(ev)) {
            int lifted = 0;
            if (ev.type == EV_ABS) {
                if (ev.code == ABS_MT_SLOT) {
                    t->slot = ev.value;
                } else if (t->slot != 0) {
                    /* Only the first finger counts. */
                } else if (ev.code == ABS_MT_POSITION_X || ev.code == ABS_X) {
                    t->x = ev.value;
                    if (t->need_start_x) { t->start_x = ev.value; t->need_start_x = 0; }
                } else if (ev.code == ABS_MT_POSITION_Y || ev.code == ABS_Y) {
                    t->y = ev.value;
                    if (t->need_start_y) { t->start_y = ev.value; t->need_start_y = 0; }
                } else if (ev.code == ABS_MT_TRACKING_ID) {
                    if (ev.value >= 0) {
                        t->down = 1;
                        t->need_start_x = t->need_start_y = 1;
                    } else {
                        lifted = t->down;
                    }
                }
            } else if (ev.type == EV_KEY && ev.code == BTN_TOUCH) {
                if (ev.value) {
                    if (!t->down) t->need_start_x = t->need_start_y = 1;
                    t->down = 1;
                } else {
                    lifted = t->down;
                }
            }
            if (lifted) {
                t->down = 0;
                /* A touch whose coordinates did not change reports none. */
                if (t->need_start_x) t->start_x = t->x;
                if (t->need_start_y) t->start_y = t->y;
                t->need_start_x = t->need_start_y = 0;
                *x = t->x;
                *y = t->y;
                return lifted_gesture(t);
            }
            continue;
        }
        if (n < 0 && errno != EAGAIN && errno != EINTR) {
            YB_ERR("input: read failed: %s", strerror(errno));
            return YB_TOUCH_ERROR;
        }

        int wait_ms = -1;
        if (timeout_ms >= 0) {
            long left = deadline - now_ms();
            if (left <= 0) return YB_TOUCH_TIMEOUT;
            wait_ms = (int)left;
        }
        struct pollfd p[2] = {
            { .fd = t->fd, .events = POLLIN },
            { .fd = extra_fd, .events = POLLIN }, /* poll ignores a negative fd */
        };
        if (poll(p, 2, wait_ms) < 0 && errno != EINTR) return YB_TOUCH_ERROR;
        if (p[1].revents) return YB_TOUCH_OTHER_FD;
    }
}

int yb_touch_wait_tap(yb_touch *t, int timeout_ms, int *x, int *y) {
    yb_touch_result r = yb_touch_wait(t, -1, timeout_ms, x, y);
    if (r == YB_TOUCH_TIMEOUT) return 0;
    if (r == YB_TOUCH_ERROR) return -1;
    return 1;
}
