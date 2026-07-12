#include "test_util.h"

#include "reader/opf.h"

#include <stdlib.h>
#include <string.h>

/* Mirrors the decrypted Bookmate opf shape (relative hrefs, spine order that
 * differs from manifest order). */
static const char *OPF =
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
    "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\">\n"
    " <metadata><dc:title>Лето с Прустом</dc:title></metadata>\n"
    " <manifest>\n"
    "  <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"
    "  <item id=\"c1\" href=\"er8laxr8.html\" media-type=\"application/xhtml+xml\"/>\n"
    "  <item id=\"c2\" href=\"0rxxu47e.html\" media-type=\"application/xhtml+xml\"/>\n"
    "  <item id=\"cov\" href=\"cover.jpg\" media-type=\"image/jpeg\"/>\n"
    " </manifest>\n"
    " <spine toc=\"ncx\">\n"
    "  <itemref idref=\"c2\"/>\n"
    "  <itemref idref=\"c1\"/>\n"
    " </spine>\n"
    "</package>\n";

int main(void) {
    char *title = NULL, **hrefs = NULL;
    size_t n = 0;
    CHECK(yb_opf_parse(OPF, strlen(OPF), &title, &hrefs, &n) == 0);
    CHECK_STR(title, "Лето с Прустом");
    CHECK(n == 2);
    if (n == 2) {
        /* order follows the spine, not the manifest */
        CHECK_STR(hrefs[0], "0rxxu47e.html");
        CHECK_STR(hrefs[1], "er8laxr8.html");
    }
    free(title);
    yb_opf_free_hrefs(hrefs, n);

    if (tests_failed == 0) printf("test_opf: OK\n");
    return tests_failed != 0;
}
