#include "reader/epub.h"

#include "reader/html.h"
#include "reader/opf.h"
#include "reader/zip.h"
#include "util/log.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* Join an OPF-relative href onto the OPF's directory and normalize "./" and
 * "../" segments. Returns malloc'd path. */
static char *resolve_href(const char *opf_path, const char *href) {
    const char *slash = strrchr(opf_path, '/');
    size_t dirlen = slash ? (size_t)(slash - opf_path + 1) : 0;

    char *full = malloc(dirlen + strlen(href) + 1);
    if (!full) return NULL;
    memcpy(full, opf_path, dirlen);
    strcpy(full + dirlen, href);

    char *segs[64];
    int n = 0;
    char *tok = strtok(full, "/");
    while (tok && n < 64) {
        if (strcmp(tok, ".") == 0) { /* skip */ }
        else if (strcmp(tok, "..") == 0) { if (n > 0) n--; }
        else segs[n++] = tok;
        tok = strtok(NULL, "/");
    }
    char *out = malloc(strlen(opf_path) + strlen(href) + 2);
    if (!out) { free(full); return NULL; }
    out[0] = '\0';
    for (int i = 0; i < n; ++i) {
        if (i) strcat(out, "/");
        strcat(out, segs[i]);
    }
    free(full);
    return out;
}

/* Find the OPF path from META-INF/container.xml. */
static char *find_opf(yb_zip *z) {
    char *container = NULL;
    size_t len = 0;
    if (yb_zip_read(z, "META-INF/container.xml", &container, &len) != 0) return NULL;
    char *rf = strstr(container, "rootfile");
    char *path = NULL;
    if (rf) {
        /* attr_get lives in opf.c; inline a tiny search here */
        char *fp = strstr(rf, "full-path");
        if (fp) {
            char *q = strchr(fp, '"');
            if (!q) q = strchr(fp, '\'');
            if (q) {
                char quote = *q++;
                char *e = strchr(q, quote);
                if (e) {
                    size_t n = (size_t)(e - q);
                    path = malloc(n + 1);
                    if (path) { memcpy(path, q, n); path[n] = '\0'; }
                }
            }
        }
    }
    free(container);
    return path;
}

static int is_html_href(const char *href) {
    const char *dot = strrchr(href, '.');
    return dot && (strcasecmp(dot, ".html") == 0 || strcasecmp(dot, ".xhtml") == 0 ||
                   strcasecmp(dot, ".htm") == 0);
}

int yb_epub_load(const char *path, yb_document *out) {
    yb_document_init(out);
    yb_zip *z = yb_zip_open(path);
    if (!z) return -1;

    char *opf_path = find_opf(z);
    if (!opf_path) { YB_ERR("epub: no OPF rootfile"); yb_zip_close(z); return -1; }

    char *opf = NULL;
    size_t opf_len = 0;
    if (yb_zip_read(z, opf_path, &opf, &opf_len) != 0) {
        YB_ERR("epub: cannot read OPF %s", opf_path);
        free(opf_path); yb_zip_close(z); return -1;
    }

    char *title = NULL, **hrefs = NULL;
    size_t nhrefs = 0;
    yb_opf_parse(opf, opf_len, &title, &hrefs, &nhrefs);
    if (title) { yb_document_set_title(out, title); free(title); }
    free(opf);

    int chapters = 0;
    for (size_t i = 0; i < nhrefs; ++i) {
        if (!is_html_href(hrefs[i])) continue;
        char *full = resolve_href(opf_path, hrefs[i]);
        char *doc = NULL;
        size_t dlen = 0;
        if (full && yb_zip_read(z, full, &doc, &dlen) == 0) {
            yb_html_to_blocks(doc, out);
            chapters++;
            free(doc);
        }
        free(full);
    }

    yb_opf_free_hrefs(hrefs, nhrefs);
    free(opf_path);
    yb_zip_close(z);

    YB_INFO("epub: loaded '%s' — %d chapter(s), %zu block(s)",
            out->title ? out->title : "(untitled)", chapters, out->count);
    return out->count > 0 ? 0 : -1;
}
