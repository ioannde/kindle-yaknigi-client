#ifndef YB_READER_PAGES_H
#define YB_READER_PAGES_H

#include "reader/render.h"

/* Where each page of a book starts for one font and page size. It makes paging
 * backwards and showing "page N of M" possible, because a page's start can only
 * be found by laying out the text before it. */
typedef struct {
    yb_pos *starts;
    size_t  count;
} yb_page_index;

/* Returns 0 on success. A document always yields at least one page. */
int  yb_page_index_build(yb_page_index *idx, yb_font *font, int w, int h,
                         const yb_document *doc, int reserve_bottom);
void yb_page_index_free(yb_page_index *idx);

/* The page containing `pos`: the last one starting at or before it. */
size_t yb_page_index_find(const yb_page_index *idx, yb_pos pos);

#endif /* YB_READER_PAGES_H */
