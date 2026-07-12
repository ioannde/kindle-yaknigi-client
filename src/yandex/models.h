#ifndef YB_YANDEX_MODELS_H
#define YB_YANDEX_MODELS_H

#include <stddef.h>
#include <cjson/cJSON.h>

/* Domain models mirrored from yandex-book-api (see PLAN.md 7). All string
 * fields are owned (malloc'd) and may be NULL when absent. */

typedef struct {
    char *small;   /* small cover URL */
    char *large;   /* large cover URL */
} yb_image;

typedef struct {
    char *uuid;
    char *name;
} yb_person;

typedef struct {
    char      *uuid;
    char      *title;
    char      *annotation;
    yb_image   cover;
    yb_person *authors;
    size_t     author_count;
} yb_book;

/* Reading state of a book in the user's library. */
typedef struct {
    yb_book book;
    int     progress;  /* 0..100 */
    char   *state;     /* "pending" | "reading" | "finished" | ... */
} yb_library_card;

typedef struct {
    yb_library_card *items;
    size_t           count;
} yb_library;

/* Parse a single book object node into `out` (zeroed first). Returns 0 on
 * success. Borrowed node; result owns its own copies. */
int  yb_book_parse(const cJSON *node, yb_book *out);
void yb_book_free(yb_book *b);

/* Parse a library-card node (a book plus progress/state). */
int  yb_library_card_parse(const cJSON *node, yb_library_card *out);
void yb_library_card_free(yb_library_card *c);

void yb_library_free(yb_library *lib);

#endif /* YB_YANDEX_MODELS_H */
