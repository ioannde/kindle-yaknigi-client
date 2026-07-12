#ifndef YB_UTIL_URL_H
#define YB_UTIL_URL_H

/* Percent-encode `s` per application/x-www-form-urlencoded rules
 * (unreserved chars pass through, everything else -> %XX). Returns a
 * malloc'd NUL-terminated string the caller owns, or NULL on OOM. */
char *yb_url_encode(const char *s);

#endif /* YB_UTIL_URL_H */
