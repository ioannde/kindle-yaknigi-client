#ifndef YB_STORAGE_BOOK_CACHE_H
#define YB_STORAGE_BOOK_CACHE_H

#include "reader/document.h"
#include "reader/render.h"

/* Downloaded books and reading positions, one pair of files per book id inside
 * `dir`. Files are replaced atomically, so a crash or a power loss leaves the
 * previous version in place. */

/* True for an id that is safe to use in a file name. */
int yb_book_id_valid(const char *id);

int yb_book_cache_save(const char *dir, const char *id, const yb_document *doc);
/* Returns 0 and fills `out`; -1 if the file is absent or damaged. */
int yb_book_cache_load(const char *dir, const char *id, yb_document *out);
int yb_book_cache_exists(const char *dir, const char *id);

int yb_book_pos_save(const char *dir, const char *id, yb_pos pos);
/* Leaves {0,0} in *pos when nothing was saved. */
void yb_book_pos_load(const char *dir, const char *id, yb_pos *pos);

/* Creates a directory and any missing parents. Returns 0 on success. */
int yb_mkdir_p(const char *path);

#endif /* YB_STORAGE_BOOK_CACHE_H */
