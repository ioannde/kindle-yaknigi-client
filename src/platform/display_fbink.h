#ifndef YB_PLATFORM_DISPLAY_FBINK_H
#define YB_PLATFORM_DISPLAY_FBINK_H

#include "platform/display.h"

#include <stddef.h>

/* E-ink panel backend. FBInk handles the differences between Kindle display
 * controllers (i.MX, MediaTek), so the same code serves every model. */

typedef struct yb_display yb_display;

yb_display *yb_display_open(void);
void        yb_display_close(yb_display *d);

int yb_display_width(const yb_display *d);
int yb_display_height(const yb_display *d);
int yb_display_dpi(const yb_display *d);

/* Writes a one-line device description for logs. */
void yb_display_describe(const yb_display *d, char *out, size_t out_size);

/* Shows a canvas of exactly the display's size. `full` adds a black flash,
 * which removes ghosting. Returns 0 on success. */
int yb_display_present(yb_display *d, const yb_canvas *c, int full);

#endif /* YB_PLATFORM_DISPLAY_FBINK_H */
