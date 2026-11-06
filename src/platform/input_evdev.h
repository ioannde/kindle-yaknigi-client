#ifndef YB_PLATFORM_INPUT_EVDEV_H
#define YB_PLATFORM_INPUT_EVDEV_H

/* Touchscreen input. While open, the device is grabbed so that touches do not
 * also reach the Kindle UI underneath. The kernel drops the grab when the
 * process ends, however it ends. */

typedef struct yb_touch yb_touch;

yb_touch *yb_touch_open(void);
void      yb_touch_close(yb_touch *t);

/* Largest raw coordinates the touch device reports. */
void yb_touch_range(const yb_touch *t, int *max_x, int *max_y);

/* Waits for a finger to lift. Returns 1 with raw coordinates, 0 on timeout,
 * -1 on error. */
int yb_touch_wait_tap(yb_touch *t, int timeout_ms, int *x, int *y);

typedef enum {
    YB_TOUCH_TIMEOUT = 0,
    YB_TOUCH_TAP = 1,
    YB_TOUCH_SWIPE_LEFT = 2,
    YB_TOUCH_SWIPE_RIGHT = 3,
    YB_TOUCH_OTHER_FD = 4, /* extra_fd became readable */
    YB_TOUCH_ERROR = -1,
} yb_touch_result;

/* Waits for a finger to lift, or for extra_fd (-1 for none) to become readable.
 * timeout_ms < 0 waits indefinitely. *x and *y get raw lift coordinates. */
yb_touch_result yb_touch_wait(yb_touch *t, int extra_fd, int timeout_ms, int *x, int *y);

/* Releases or retakes the device, so that the Kindle lock screen can use it. */
void yb_touch_set_grab(yb_touch *t, int grabbed);

#endif /* YB_PLATFORM_INPUT_EVDEV_H */
