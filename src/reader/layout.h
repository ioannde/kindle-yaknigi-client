#ifndef YB_READER_LAYOUT_H
#define YB_READER_LAYOUT_H

#include <stddef.h>

/* Pure line-breaking used by the renderer and testable without any font code.
 * Text width is supplied through a measure callback so the same logic works
 * with real FreeType metrics or a fixed-width stub in tests. */

typedef struct {
    size_t off;  /* byte offset of the line within the paragraph text */
    size_t len;  /* byte length of the line (trailing space trimmed) */
} yb_line;

/* Measure the pixel width of the UTF-8 substring [text, text+len). */
typedef int (*yb_measure_fn)(void *ctx, const char *text, size_t len);

/* Break `text` into lines no wider than max_w, splitting on spaces (a single
 * word longer than max_w occupies its own line). Allocates a fresh array into
 * *out_lines (caller frees) and returns the number of lines. */
size_t yb_wrap_paragraph(const char *text, int max_w,
                         yb_measure_fn measure, void *ctx,
                         yb_line **out_lines);

#endif /* YB_READER_LAYOUT_H */
