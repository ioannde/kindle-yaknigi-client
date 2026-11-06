#include "test_util.h"

#include "reader/pages.h"

#include <stdlib.h>

/* Needs a real font: the path comes from YB_TEST_FONT, and without it the test
 * only checks the search. */
static void check_find(void) {
    yb_pos starts[] = { { 0, 0 }, { 0, 500 }, { 3, 0 }, { 3, 80 } };
    yb_page_index idx = { starts, 4 };
    CHECK(yb_page_index_find(&idx, (yb_pos){ 0, 0 }) == 0);
    CHECK(yb_page_index_find(&idx, (yb_pos){ 0, 499 }) == 0);
    CHECK(yb_page_index_find(&idx, (yb_pos){ 0, 500 }) == 1);
    CHECK(yb_page_index_find(&idx, (yb_pos){ 2, 9999 }) == 1);
    CHECK(yb_page_index_find(&idx, (yb_pos){ 3, 79 }) == 2);
    CHECK(yb_page_index_find(&idx, (yb_pos){ 99, 0 }) == 3);
}

int main(void) {
    check_find();

    const char *path = getenv("YB_TEST_FONT");
    yb_font *font = path ? yb_font_load(path, 30) : NULL;
    if (font) {
        yb_document d;
        yb_document_init(&d);
        char para[4000]; /* 300 words of 11 bytes each */
        memset(para, 0, sizeof(para));
        for (int i = 0; i < 300; ++i) strcat(para, "слово ");
        for (int i = 0; i < 40; ++i) yb_document_add(&d, i % 10 == 0, para);

        yb_page_index idx;
        CHECK(yb_page_index_build(&idx, font, 600, 800, &d, 40) == 0);
        CHECK(idx.count > 5);

        /* Drawing must stop exactly where the index says the next page starts. */
        yb_canvas *c = yb_canvas_new(600, 800, 150);
        for (size_t i = 0; i < idx.count; ++i) {
            int done = 0;
            yb_pos next = yb_render_page_ex(font, c, 600, 800, &d, idx.starts[i], 40, &done);
            if (i + 1 < idx.count) {
                CHECK(!done);
                CHECK(next.block == idx.starts[i + 1].block);
                CHECK(next.line_off == idx.starts[i + 1].line_off);
            } else {
                CHECK(done);
            }
        }
        yb_canvas_free(c);
        yb_page_index_free(&idx);
        yb_document_free(&d);
        yb_font_free(font);
    }

    if (!tests_failed) printf("test_pages: OK\n");
    return tests_failed != 0;
}
