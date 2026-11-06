#include "test_util.h"

#include "storage/book_cache.h"

#include <unistd.h>

#include <stdlib.h>

int main(void) {
    char dir[] = "/tmp/yb_cache_XXXXXX";
    CHECK(mkdtemp(dir) != NULL);

    CHECK(!yb_book_id_valid("../../etc/passwd"));
    CHECK(!yb_book_id_valid(""));
    CHECK(yb_book_id_valid("a1B2-c3_d"));
    CHECK(yb_book_cache_save(dir, "../evil", NULL) != 0);

    yb_document d, r;
    yb_document_init(&d);
    yb_document_set_title(&d, "Заголовок");
    yb_document_add(&d, 1, "Глава");
    yb_document_add(&d, 0, "Текст абзаца");
    CHECK(!yb_book_cache_exists(dir, "b1"));
    CHECK(yb_book_cache_save(dir, "b1", &d) == 0);
    CHECK(yb_book_cache_exists(dir, "b1"));
    CHECK(yb_book_cache_load(dir, "b1", &r) == 0);
    CHECK_STR(r.title, "Заголовок");
    CHECK(r.count == 2);
    CHECK(r.count == 2 && r.blocks[0].heading == 1);
    CHECK_STR(r.count == 2 ? r.blocks[1].text : NULL, "Текст абзаца");
    yb_document_free(&r);
    yb_document_free(&d);

    /* A cut-off or foreign file must be refused, never read past its end. */
    char path[1024];
    snprintf(path, sizeof(path), "%s/b1.book", dir);
    CHECK(truncate(path, 20) == 0);
    CHECK(yb_book_cache_load(dir, "b1", &r) != 0);
    FILE *f = fopen(path, "wb");
    fputs("not a book", f);
    fclose(f);
    CHECK(yb_book_cache_load(dir, "b1", &r) != 0);
    CHECK(yb_book_cache_load(dir, "absent", &r) != 0);

    yb_pos p = { 7, 7 };
    yb_book_pos_load(dir, "b1", &p);
    CHECK(p.block == 0 && p.line_off == 0);
    CHECK(yb_book_pos_save(dir, "b1", (yb_pos){ 12, 345 }) == 0);
    yb_book_pos_load(dir, "b1", &p);
    CHECK(p.block == 12 && p.line_off == 345);

    if (!tests_failed) printf("test_book_cache: OK\n");
    return tests_failed != 0;
}
