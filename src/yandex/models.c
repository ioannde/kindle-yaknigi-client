#include "yandex/models.h"

#include "yandex/json.h"

#include <stdlib.h>
#include <string.h>

/* Cover shape varies across endpoints; accept either a flat object with
 * small/large URLs or nested "image"/"urls". Kept defensive on purpose — the
 * exact schema is pinned down in Phase 0. */
static void parse_cover(const cJSON *book_node, yb_image *img) {
    const cJSON *cover = yb_json_obj(book_node, "cover");
    if (!cover) return;
    img->small = yb_json_dup_string(cover, "small");
    img->large = yb_json_dup_string(cover, "large");
}

static void parse_authors(const cJSON *book_node, yb_book *out) {
    const cJSON *arr = yb_json_obj(book_node, "authors_objects");
    if (!cJSON_IsArray(arr)) arr = yb_json_obj(book_node, "authors");
    if (!cJSON_IsArray(arr)) return;

    int n = cJSON_GetArraySize(arr);
    if (n <= 0) return;
    out->authors = calloc((size_t)n, sizeof(yb_person));
    if (!out->authors) return;

    size_t count = 0;
    for (int i = 0; i < n; ++i) {
        const cJSON *a = cJSON_GetArrayItem(arr, i);
        if (!cJSON_IsObject(a)) continue;
        out->authors[count].uuid = yb_json_dup_string(a, "uuid");
        out->authors[count].name = yb_json_dup_string(a, "name");
        count++;
    }
    out->author_count = count;
}

int yb_book_parse(const cJSON *node, yb_book *out) {
    memset(out, 0, sizeof(*out));
    if (!cJSON_IsObject(node)) return -1;
    out->uuid = yb_json_dup_string(node, "uuid");
    out->title = yb_json_dup_string(node, "title");
    out->annotation = yb_json_dup_string(node, "annotation");
    parse_cover(node, &out->cover);
    parse_authors(node, out);
    return 0;
}

void yb_book_free(yb_book *b) {
    if (!b) return;
    free(b->uuid);
    free(b->title);
    free(b->annotation);
    free(b->cover.small);
    free(b->cover.large);
    for (size_t i = 0; i < b->author_count; ++i) {
        free(b->authors[i].uuid);
        free(b->authors[i].name);
    }
    free(b->authors);
    memset(b, 0, sizeof(*b));
}

int yb_library_card_parse(const cJSON *node, yb_library_card *out) {
    memset(out, 0, sizeof(*out));
    if (!cJSON_IsObject(node)) return -1;

    /* A card may embed the book under "book", or the node may itself be the
     * book with progress fields attached. */
    const cJSON *book_node = yb_json_obj(node, "book");
    if (!cJSON_IsObject(book_node)) book_node = node;

    if (yb_book_parse(book_node, &out->book) != 0) return -1;
    out->progress = yb_json_int(node, "progress", 0);
    out->state = yb_json_dup_string(node, "state");
    return 0;
}

void yb_library_card_free(yb_library_card *c) {
    if (!c) return;
    yb_book_free(&c->book);
    free(c->state);
    memset(c, 0, sizeof(*c));
}

void yb_library_free(yb_library *lib) {
    if (!lib) return;
    for (size_t i = 0; i < lib->count; ++i) yb_library_card_free(&lib->items[i]);
    free(lib->items);
    lib->items = NULL;
    lib->count = 0;
}
