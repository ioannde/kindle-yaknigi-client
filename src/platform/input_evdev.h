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

#endif /* YB_PLATFORM_INPUT_EVDEV_H */
