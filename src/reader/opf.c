#include "reader/opf.h"

#include "reader/html.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

/* Extract attribute value: searches [start,end) for `attr`="value" (single or
 * double quotes). Returns malloc'd value or NULL. */
static char *attr_get(const char *start, const char *end, const char *attr) {
    size_t alen = strlen(attr);
    for (const char *p = start; p + alen < end; ++p) {
        if (strncmp(p, attr, alen) != 0) continue;
        if (p != start && !isspace((unsigned char)p[-1])) continue;
        const char *q = p + alen;
        while (q < end && isspace((unsigned char)*q)) q++;
        if (q >= end || *q != '=') continue;
        q++;
        while (q < end && isspace((unsigned char)*q)) q++;
        if (q >= end || (*q != '"' && *q != '\'')) continue;
        char quote = *q++;
        const char *v = q;
        while (q < end && *q != quote) q++;
        if (q >= end) return NULL;
        size_t vl = (size_t)(q - v);
        char *out = malloc(vl + 1);
        if (!out) return NULL;
        memcpy(out, v, vl);
        out[vl] = '\0';
        return out;
    }
    return NULL;
}

int yb_opf_parse(const char *opf, size_t len,
                 char **title_out, char ***hrefs_out, size_t *count_out) {
    if (title_out) *title_out = NULL;
    *hrefs_out = NULL;
    *count_out = 0;
    const char *opf_end = opf + len;

    /* title */
    if (title_out) {
        const char *tstart = strstr(opf, "<dc:title");
        if (!tstart) tstart = strstr(opf, "<title");
        if (tstart) {
            const char *gt = strchr(tstart, '>');
            const char *close = gt ? strstr(gt, "</") : NULL;
            if (gt && close)
                *title_out = yb_html_clean_text(gt + 1, (size_t)(close - gt - 1));
        }
    }

    /* manifest: id -> href (parallel arrays) */
    char **ids = NULL, **hrefs = NULL;
    size_t man_n = 0, man_cap = 0;
    for (const char *p = opf; (p = strstr(p, "<item ")) != NULL; ) {
        const char *gt = strchr(p, '>');
        if (!gt) break;
        char *id = attr_get(p, gt, "id");
        char *href = attr_get(p, gt, "href");
        if (id && href) {
            if (man_n == man_cap) {
                man_cap = man_cap ? man_cap * 2 : 32;
                ids = realloc(ids, man_cap * sizeof(char *));
                hrefs = realloc(hrefs, man_cap * sizeof(char *));
            }
            ids[man_n] = id;
            hrefs[man_n] = href;
            man_n++;
        } else { free(id); free(href); }
        p = gt + 1;
    }

    /* spine: itemref idref order -> collect hrefs */
    const char *spine = strstr(opf, "<spine");
    const char *scan = spine ? spine : opf;
    char **out = NULL;
    size_t out_n = 0, out_cap = 0;
    for (const char *p = scan; (p = strstr(p, "<itemref")) != NULL; ) {
        const char *gt = strchr(p, '>');
        if (!gt || gt > opf_end) break;
        char *idref = attr_get(p, gt, "idref");
        p = gt + 1;
        if (!idref) continue;

        const char *href = NULL;
        for (size_t i = 0; i < man_n; ++i)
            if (strcmp(ids[i], idref) == 0) { href = hrefs[i]; break; }
        free(idref);
        if (!href) continue;

        if (out_n == out_cap) {
            out_cap = out_cap ? out_cap * 2 : 32;
            out = realloc(out, out_cap * sizeof(char *));
        }
        out[out_n++] = strdup(href);
    }

    for (size_t i = 0; i < man_n; ++i) { free(ids[i]); free(hrefs[i]); }
    free(ids); free(hrefs);

    *hrefs_out = out;
    *count_out = out_n;
    return 0;
}

void yb_opf_free_hrefs(char **hrefs, size_t count) {
    for (size_t i = 0; i < count; ++i) free(hrefs[i]);
    free(hrefs);
}
