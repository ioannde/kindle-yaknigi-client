/* Host reader tool: turns a real .epub into page images (PGM), exercising the
 * full reader engine — ZIP -> EPUB parse -> text -> wrap -> FreeType raster.
 * No Yandex/network involved: this proves the reading pipeline end-to-end on
 * any book file today; only "fetch from Yandex" waits on Phase 0.
 *
 * Usage:  yb-render <book.epub> <out-dir> [max-pages]
 * Env:    YB_FONT     path to a TTF (default: DejaVuSans)
 *         YB_FONT_PX  font pixel size (default: 30)
 *         YB_SCREEN_W, YB_SCREEN_H, YB_SCREEN_DPI  canvas size (default PW5)
 */
#include "platform/display.h"
#include "reader/epub.h"
#include "reader/render.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *font_path(void) {
    const char *e = getenv("YB_FONT");
    if (e && *e) return e;
    return "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
}

static int env_int(const char *name, int dflt) {
    const char *e = getenv(name);
    return (e && *e) ? atoi(e) : dflt;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <book.epub> <out-dir> [max-pages]\n", argv[0]);
        return 2;
    }
    const char *epub = argv[1];
    const char *outdir = argv[2];
    int max_pages = argc > 3 ? atoi(argv[3]) : 5;

    yb_document doc;
    if (yb_epub_load(epub, &doc) != 0) {
        fprintf(stderr, "error: could not load EPUB %s\n", epub);
        return 1;
    }
    printf("Title: %s\n", doc.title ? doc.title : "(untitled)");
    printf("Blocks: %zu\n", doc.count);
    if (doc.missing_chapters)
        printf("WARNING: incomplete book, %zu chapter(s) missing\n", doc.missing_chapters);

    int w = env_int("YB_SCREEN_W", 1236);      /* PW5 default */
    int h = env_int("YB_SCREEN_H", 1648);
    int dpi = env_int("YB_SCREEN_DPI", 300);
    int px = env_int("YB_FONT_PX", 30);

    yb_font *font = yb_font_load(font_path(), px);
    if (!font) {
        fprintf(stderr, "error: could not load font %s\n", font_path());
        yb_document_free(&doc);
        return 1;
    }
    yb_canvas *c = yb_canvas_new(w, h, dpi);
    if (!c) { yb_font_free(font); yb_document_free(&doc); return 1; }

    yb_pos pos = { 0, 0 };
    int done = 0;
    int page = 0;
    while (!done && page < max_pages) {
        pos = yb_render_page(font, c, &doc, pos, &done);
        char path[1024];
        snprintf(path, sizeof(path), "%s/page-%03d.pgm", outdir, page + 1);
        if (yb_canvas_save_pgm(c, path) == 0)
            printf("  wrote %s\n", path);
        page++;
    }
    printf("Rendered %d page(s)%s.\n", page, done ? " (end of book)" : "");

    yb_canvas_free(c);
    yb_font_free(font);
    yb_document_free(&doc);
    return 0;
}
