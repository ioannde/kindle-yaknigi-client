#include "platform/display_fbink.h"

#include "util/log.h"

#include <fbink.h>
#include <stdio.h>
#include <stdlib.h>

struct yb_display {
    int         fd;
    FBInkConfig cfg;
    FBInkState  state;
};

yb_display *yb_display_open(void) {
    yb_display *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->fd = fbink_open();
    if (d->fd < 0) {
        YB_ERR("display: cannot open the framebuffer");
        free(d);
        return NULL;
    }
    d->cfg.ignore_alpha = true;
    d->cfg.wfm_mode = WFM_GC16;
    if (fbink_init(d->fd, &d->cfg) != 0) {
        YB_ERR("display: FBInk init failed");
        fbink_close(d->fd);
        free(d);
        return NULL;
    }
    fbink_get_state(&d->cfg, &d->state);
    return d;
}

void yb_display_close(yb_display *d) {
    if (!d) return;
    fbink_close(d->fd);
    free(d);
}

int yb_display_width(const yb_display *d) { return (int)d->state.view_width; }
int yb_display_height(const yb_display *d) { return (int)d->state.view_height; }
int yb_display_dpi(const yb_display *d) { return d->state.screen_dpi; }

void yb_display_describe(const yb_display *d, char *out, size_t out_size) {
    snprintf(out, out_size, "FBInk %s, Kindle %s (%s), %ux%u, %u dpi, %u bpp, mtk=%d",
             fbink_version(), d->state.device_name, d->state.device_codename,
             d->state.view_width, d->state.view_height, d->state.screen_dpi,
             d->state.bpp, d->state.is_kindle_mtk ? 1 : 0);
}

int yb_display_present(yb_display *d, const yb_canvas *c, int full) {
    if (c->w != yb_display_width(d) || c->h != yb_display_height(d)) {
        YB_ERR("display: canvas %dx%d does not match the panel", c->w, c->h);
        return -1;
    }
    d->cfg.is_flashing = full ? true : false;
    size_t len = (size_t)c->w * (size_t)c->h;
    int rc = fbink_print_raw_data(d->fd, c->pix, c->w, c->h, len, 0, 0, &d->cfg);
    if (rc < 0) {
        YB_ERR("display: FBInk draw failed (%d)", rc);
        return -1;
    }
    return 0;
}
