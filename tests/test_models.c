#include "test_util.h"

#include "yandex/models.h"

#include <cjson/cJSON.h>
#include <stdlib.h>

/* A library response resembling the expected envelope: an "items" array of
 * cards, each with progress/state and an embedded book. Exact schema is
 * confirmed in Phase 0; the parser is deliberately tolerant. */
static const char *SAMPLE =
    "{\"items\":["
    "  {\"progress\":42,\"state\":\"reading\",\"book\":{"
    "     \"uuid\":\"b-1\",\"title\":\"Война и мир\","
    "     \"annotation\":\"...\","
    "     \"cover\":{\"small\":\"s.jpg\",\"large\":\"l.jpg\"},"
    "     \"authors_objects\":[{\"uuid\":\"a-1\",\"name\":\"Лев Толстой\"}]"
    "  }},"
    "  {\"progress\":100,\"state\":\"finished\",\"book\":{"
    "     \"uuid\":\"b-2\",\"title\":\"Идиот\","
    "     \"authors\":[{\"name\":\"Фёдор Достоевский\"}]"
    "  }}"
    "]}";

static const cJSON *find_items(const cJSON *root) {
    return cJSON_GetObjectItemCaseSensitive(root, "items");
}

int main(void) {
    cJSON *root = cJSON_Parse(SAMPLE);
    CHECK(root != NULL);
    const cJSON *arr = find_items(root);
    CHECK(cJSON_IsArray(arr));
    CHECK(cJSON_GetArraySize(arr) == 2);

    yb_library_card c0;
    CHECK(yb_library_card_parse(cJSON_GetArrayItem(arr, 0), &c0) == 0);
    CHECK(c0.progress == 42);
    CHECK_STR(c0.state, "reading");
    CHECK_STR(c0.book.uuid, "b-1");
    CHECK_STR(c0.book.title, "Война и мир");
    CHECK_STR(c0.book.cover.small, "s.jpg");
    CHECK_STR(c0.book.cover.large, "l.jpg");
    CHECK(c0.book.author_count == 1);
    CHECK_STR(c0.book.authors[0].name, "Лев Толстой");
    yb_library_card_free(&c0);

    yb_library_card c1;
    CHECK(yb_library_card_parse(cJSON_GetArrayItem(arr, 1), &c1) == 0);
    CHECK(c1.progress == 100);
    CHECK_STR(c1.book.title, "Идиот");
    CHECK(c1.book.author_count == 1);
    CHECK_STR(c1.book.authors[0].name, "Фёдор Достоевский");
    /* missing fields must be NULL, not crash */
    CHECK(c1.book.annotation == NULL);
    CHECK(c1.book.cover.small == NULL);
    yb_library_card_free(&c1);

    cJSON_Delete(root);

    /* a bare book node (no "book" wrapper) must also parse */
    cJSON *bare = cJSON_Parse("{\"uuid\":\"x\",\"title\":\"T\"}");
    yb_book b;
    CHECK(yb_book_parse(bare, &b) == 0);
    CHECK_STR(b.title, "T");
    yb_book_free(&b);
    cJSON_Delete(bare);

    if (tests_failed == 0) printf("test_models: OK\n");
    return tests_failed != 0;
}
