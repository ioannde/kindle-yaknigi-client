#ifndef YB_UTIL_LOG_H
#define YB_UTIL_LOG_H

/* Minimal leveled logging to stderr. On device we keep it lightweight;
 * verbosity is controlled by the YB_LOG env var (error|warn|info|debug). */

typedef enum { YB_LOG_ERROR = 0, YB_LOG_WARN, YB_LOG_INFO, YB_LOG_DEBUG } yb_log_level;

void yb_log_set_level(yb_log_level level);
void yb_log(yb_log_level level, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

#define YB_ERR(...)  yb_log(YB_LOG_ERROR, __VA_ARGS__)
#define YB_WARN(...) yb_log(YB_LOG_WARN, __VA_ARGS__)
#define YB_INFO(...) yb_log(YB_LOG_INFO, __VA_ARGS__)
#define YB_DEBUG(...) yb_log(YB_LOG_DEBUG, __VA_ARGS__)

#endif /* YB_UTIL_LOG_H */
