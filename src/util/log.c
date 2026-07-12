#include "util/log.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static yb_log_level g_level = YB_LOG_INFO;
static int g_level_from_env = 0;

static void init_from_env(void) {
    if (g_level_from_env) return;
    g_level_from_env = 1;
    const char *e = getenv("YB_LOG");
    if (!e) return;
    if (strcmp(e, "error") == 0) g_level = YB_LOG_ERROR;
    else if (strcmp(e, "warn") == 0) g_level = YB_LOG_WARN;
    else if (strcmp(e, "info") == 0) g_level = YB_LOG_INFO;
    else if (strcmp(e, "debug") == 0) g_level = YB_LOG_DEBUG;
}

void yb_log_set_level(yb_log_level level) {
    g_level = level;
    g_level_from_env = 1; /* explicit call wins over env */
}

void yb_log(yb_log_level level, const char *fmt, ...) {
    init_from_env();
    if (level > g_level) return;

    static const char *tag[] = { "ERROR", "WARN", "INFO", "DEBUG" };
    fprintf(stderr, "[%s] ", tag[level]);

    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);

    fputc('\n', stderr);
}
