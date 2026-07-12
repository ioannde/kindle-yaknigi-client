#include "test_util.h"

#include "reader/zip.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Hand-built ZIP with one STORED entry "a.txt" -> "hi\n". Exercises the
 * central-directory parse and the stored extraction path. (Deflate is
 * exercised end-to-end by yb-render on real EPUBs.) */
static const unsigned char ZIP[] = {
    /* local file header */
    0x50,0x4b,0x03,0x04, 0x14,0x00, 0x00,0x00, 0x00,0x00,
    0x00,0x00, 0x00,0x00, 0x00,0x00,0x00,0x00,          /* crc */
    0x03,0x00,0x00,0x00, 0x03,0x00,0x00,0x00,            /* comp, uncomp */
    0x05,0x00, 0x00,0x00,                                /* namelen, extralen */
    'a','.','t','x','t',
    'h','i','\n',
    /* central directory header */
    0x50,0x4b,0x01,0x02, 0x14,0x00, 0x14,0x00, 0x00,0x00, 0x00,0x00,
    0x00,0x00, 0x00,0x00, 0x00,0x00,0x00,0x00,           /* crc */
    0x03,0x00,0x00,0x00, 0x03,0x00,0x00,0x00,             /* comp, uncomp */
    0x05,0x00, 0x00,0x00, 0x00,0x00,                      /* namelen, extralen, commentlen */
    0x00,0x00, 0x00,0x00, 0x00,0x00,0x00,0x00,            /* disk, iattr, eattr */
    0x00,0x00,0x00,0x00,                                  /* local header offset */
    'a','.','t','x','t',
    /* end of central directory */
    0x50,0x4b,0x05,0x06, 0x00,0x00, 0x00,0x00,
    0x01,0x00, 0x01,0x00,                                 /* entries */
    0x33,0x00,0x00,0x00,                                  /* cd size = 51 */
    0x26,0x00,0x00,0x00,                                  /* cd offset = 38 */
    0x00,0x00,                                            /* comment len */
};

int main(void) {
    const char *path = "test_zip_tmp.zip";
    FILE *f = fopen(path, "wb");
    CHECK(f != NULL);
    if (!f) return 1;
    fwrite(ZIP, 1, sizeof(ZIP), f);
    fclose(f);

    yb_zip *z = yb_zip_open(path);
    CHECK(z != NULL);
    if (z) {
        CHECK(yb_zip_count(z) == 1);
        CHECK_STR(yb_zip_name(z, 0), "a.txt");

        char *data = NULL;
        size_t len = 0;
        CHECK(yb_zip_read(z, "a.txt", &data, &len) == 0);
        CHECK(len == 3);
        CHECK_STR(data, "hi\n");
        free(data);

        CHECK(yb_zip_read(z, "missing", &data, &len) == -1);
        yb_zip_close(z);
    }
    remove(path);

    if (tests_failed == 0) printf("test_zip: OK\n");
    return tests_failed != 0;
}
