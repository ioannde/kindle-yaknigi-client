#include "app/app.h"

#include "reader/pages.h"
#include "reader/render.h"
#include "storage/book_cache.h"
#include "storage/config.h"
#include "third_party/qrcodegen.h"
#include "util/log.h"
#include "yandex/api.h"
#include "yandex/auth.h"
#include "yandex/content.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The app's registration at oauth.yandex.ru. This value is public. */
#define YB_CLIENT_ID "CLIENT_ID_REMOVED"

#define LIB_ROWS 8
#define MAX_CODE 40
#define FULL_REFRESH_EVERY 8

typedef struct {
    yb_host *host;
    yb_canvas *c;
    const yb_app_paths *paths;
    yb_font *ui;
    yb_font *small;
    yb_config *cfg;
    char books_dir[1024];
    char library_path[1024];
} app;

typedef struct { int x, y, w, h; } rect;

typedef struct {
    char *id;
    char *title;
    char *author;
} lib_item;

typedef struct {
    lib_item *items;
    size_t count;
} lib_list;

typedef enum { GO_BACK, GO_EXIT, GO_LOGIN } nav;

/* --- drawing -------------------------------------------------------------- */

static void fill(yb_canvas *c, rect r, uint8_t value) {
    for (int y = r.y; y < r.y + r.h; ++y) {
        if (y < 0 || y >= c->h) continue;
        for (int x = r.x; x < r.x + r.w; ++x)
            if (x >= 0 && x < c->w) c->pix[y * c->w + x] = value;
    }
}

static void frame(yb_canvas *c, rect r, int t) {
    fill(c, (rect){ r.x, r.y, r.w, t }, 0);
    fill(c, (rect){ r.x, r.y + r.h - t, r.w, t }, 0);
    fill(c, (rect){ r.x, r.y, t, r.h }, 0);
    fill(c, (rect){ r.x + r.w - t, r.y, t, r.h }, 0);
}

static int inside(rect r, int x, int y) {
    return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
}

static void text_centered(yb_font *f, yb_canvas *c, rect r, const char *s) {
    int x = r.x + (r.w - yb_font_text_width(f, s)) / 2;
    int y = r.y + (r.h - yb_font_line_height(f)) / 2 + yb_font_ascender(f);
    yb_font_draw_text(f, c, x, y, s);
}

static void button(app *a, rect r, const char *label) {
    frame(a->c, r, 3);
    text_centered(a->ui, a->c, r, label);
}

/* Copies `text` into `out`, cut at a character boundary with an ellipsis so that
 * it fits max_w. */
static void fit_text(yb_font *f, const char *text, int max_w, char *out, size_t out_size) {
    snprintf(out, out_size, "%s", text);
    size_t n = strlen(out);
    if (n + 1 == out_size) {
        while (n > 0 && ((unsigned char)out[n] & 0xC0) == 0x80) n--;
        out[n] = '\0';
    }
    if (yb_font_text_width(f, out) <= max_w) return;
    const char *dots = "…";
    size_t dl = strlen(dots);
    for (;;) {
        while (n > 0) {
            n--;
            if (((unsigned char)out[n] & 0xC0) != 0x80) break;
        }
        if (n + dl + 1 > out_size) continue;
        memcpy(out + n, dots, dl + 1);
        if (n == 0 || yb_font_text_width(f, out) <= max_w) return;
    }
}

static void present(app *a, int full) {
    a->host->present(a->host->ctx, a->c, full);
}

static void wait_event(app *a, yb_event *ev) {
    a->host->wait_event(a->host->ctx, -1, ev);
    if (ev->type != YB_EV_TIMEOUT && ev->type != YB_EV_QUIT)
        a->host->keep_awake(a->host->ctx);
}

/* A full-screen wrapped message, using the book renderer's layout. */
static void draw_message(app *a, const char *heading, const char *text) {
    yb_document d;
    yb_document_init(&d);
    if (heading) yb_document_add(&d, 1, heading);
    if (text) yb_document_add(&d, 0, text);
    yb_render_page(a->ui, a->c, &d, (yb_pos){ 0, 0 }, NULL);
    yb_document_free(&d);
}

static void show_message(app *a, const char *heading, const char *text) {
    draw_message(a, heading, text);
    present(a, 0);
}

/* Shows an error until the user taps. Returns 0 if the app should quit. */
static int show_error(app *a, const char *heading, const char *text) {
    int full = 0;
    for (;;) {
        draw_message(a, heading, text);
        text_centered(a->ui, a->c,
                      (rect){ 0, a->c->h * 8 / 10, a->c->w, a->c->h / 10 },
                      "Коснитесь экрана, чтобы продолжить");
        present(a, full);
        yb_event ev;
        wait_event(a, &ev);
        if (ev.type == YB_EV_QUIT) return 0;
        if (ev.type == YB_EV_WAKE) { full = 1; continue; }
        if (ev.type == YB_EV_TAP || ev.type == YB_EV_SWIPE_LEFT ||
            ev.type == YB_EV_SWIPE_RIGHT)
            return 1;
    }
}

/* --- login ---------------------------------------------------------------- */

static const char *const KEY_ROWS[] = { "1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm" };
#define KEY_ROW_COUNT 4
#define KEY_BACKSPACE 8

typedef struct {
    rect qr;
    rect field;
    rect submit;
    rect leave;
    int key_w, key_h, keys_y;
    int text_y;
} login_layout;

static login_layout login_geometry(const app *a) {
    login_layout l;
    int w = a->c->w, h = a->c->h;
    int m = w / 30;
    l.key_w = (w - 2 * m) / 10;
    l.key_h = l.key_w * 9 / 10;
    int action_h = l.key_h;
    l.submit = (rect){ m, h - m - action_h, (w - 2 * m) * 2 / 3 - m / 2, action_h };
    l.leave = (rect){ l.submit.x + l.submit.w + m, l.submit.y,
                      w - 2 * m - l.submit.w - m, action_h };
    l.keys_y = l.submit.y - m / 2 - KEY_ROW_COUNT * l.key_h;
    l.field = (rect){ m, l.keys_y - m - l.key_h, w - 2 * m, l.key_h };
    l.text_y = l.field.y - m / 2 - 2 * yb_font_line_height(a->small);
    return l;
}

static rect key_rect(const login_layout *l, const app *a, int row, int col) {
    int len = (int)strlen(KEY_ROWS[row]);
    int cells = row == KEY_ROW_COUNT - 1 ? len + 2 : len; /* room for backspace */
    int x0 = (a->c->w - cells * l->key_w) / 2;
    return (rect){ x0 + col * l->key_w, l->keys_y + row * l->key_h, l->key_w, l->key_h };
}

static rect backspace_rect(const login_layout *l, const app *a) {
    rect r = key_rect(l, a, KEY_ROW_COUNT - 1, (int)strlen(KEY_ROWS[KEY_ROW_COUNT - 1]));
    r.w = 2 * l->key_w;
    return r;
}

static void draw_login(app *a, const login_layout *l, const uint8_t *qr,
                       const char *code, const char *error) {
    yb_canvas *c = a->c;
    yb_canvas_clear(c, 0xFF);
    int m = c->w / 30;
    int y = m + yb_font_ascender(a->ui);
    yb_font_draw_text(a->ui, c, m, y, "Вход в Яндекс Книги");
    y += yb_font_line_height(a->ui);
    yb_font_draw_text(a->small, c, m, y, "1. Отсканируйте код телефоном и войдите в Яндекс.");

    int qr_top = y + yb_font_line_height(a->small);
    int qr_room = l->text_y - qr_top - m / 2;
    int size = qrcodegen_getSize(qr);
    int quiet = 4; /* blank border scanners need around the code */
    int avail = qr_room < c->w - 2 * m ? qr_room : c->w - 2 * m;
    int scale = avail / (size + 2 * quiet);
    if (scale < 1) scale = 1;
    int side = size * scale;
    int qx = (c->w - side) / 2, qy = qr_top + (qr_room - side) / 2;
    for (int my = 0; my < size; ++my)
        for (int mx = 0; mx < size; ++mx)
            if (qrcodegen_getModule(qr, mx, my))
                fill(c, (rect){ qx + mx * scale, qy + my * scale, scale, scale }, 0);

    int ty = l->text_y + yb_font_ascender(a->small);
    if (error) {
        yb_font_draw_text(a->small, c, m, ty, error);
    } else {
        yb_font_draw_text(a->small, c, m, ty, "2. Введите код подтверждения, который покажет Яндекс:");
    }

    frame(c, l->field, 3);
    text_centered(a->ui, c, l->field, *code ? code : " ");

    for (int row = 0; row < KEY_ROW_COUNT; ++row) {
        size_t len = strlen(KEY_ROWS[row]);
        for (size_t col = 0; col < len; ++col) {
            char label[2] = { KEY_ROWS[row][col], '\0' };
            rect r = key_rect(l, a, row, (int)col);
            frame(c, r, 2);
            text_centered(a->ui, c, r, label);
        }
    }
    rect bs = backspace_rect(l, a);
    frame(c, bs, 2);
    text_centered(a->ui, c, bs, "←");
    button(a, l->submit, "Войти");
    button(a, l->leave, "Выход");
}

static void login_key(const login_layout *l, const app *a, int x, int y, char *code) {
    size_t n = strlen(code);
    if (inside(backspace_rect(l, a), x, y)) {
        if (n) code[n - 1] = '\0';
        return;
    }
    if (n >= MAX_CODE) return;
    for (int row = 0; row < KEY_ROW_COUNT; ++row) {
        size_t len = strlen(KEY_ROWS[row]);
        for (size_t col = 0; col < len; ++col) {
            if (inside(key_rect(l, a, row, (int)col), x, y)) {
                code[n] = KEY_ROWS[row][col];
                code[n + 1] = '\0';
                return;
            }
        }
    }
}

/* Returns GO_BACK once a token is stored, GO_EXIT if the user leaves. */
static nav login_screen(app *a) {
    char verifier[YB_PKCE_VERIFIER_LEN + 1], challenge[64];
    if (yb_pkce_new_verifier(verifier) != 0 || yb_pkce_challenge(verifier, challenge) != 0) {
        show_error(a, "Ошибка", "Не удалось подготовить вход.");
        return GO_EXIT;
    }
    char *url = yb_auth_pkce_url(YB_CLIENT_ID, challenge);
    uint8_t *qr = malloc(qrcodegen_BUFFER_LEN_MAX);
    uint8_t *tmp = malloc(qrcodegen_BUFFER_LEN_MAX);
    if (!url || !qr || !tmp ||
        !qrcodegen_encodeText(url, tmp, qr, qrcodegen_Ecc_LOW, qrcodegen_VERSION_MIN,
                              qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO, true)) {
        free(url); free(qr); free(tmp);
        show_error(a, "Ошибка", "Не удалось подготовить вход.");
        return GO_EXIT;
    }
    free(url);
    free(tmp);

    login_layout l = login_geometry(a);
    char code[MAX_CODE + 1] = "";
    const char *error = NULL;
    int full = 1;
    nav result = GO_EXIT;
    for (;;) {
        draw_login(a, &l, qr, code, error);
        present(a, full);
        full = 0;

        yb_event ev;
        wait_event(a, &ev);
        if (ev.type == YB_EV_QUIT) break;
        if (ev.type == YB_EV_WAKE) { full = 1; continue; }
        if (ev.type != YB_EV_TAP) continue;

        if (inside(l.leave, ev.x, ev.y)) break;
        if (!inside(l.submit, ev.x, ev.y)) {
            login_key(&l, a, ev.x, ev.y, code);
            error = NULL;
            continue;
        }
        if (!*code) continue;

        show_message(a, "Проверяю код…", NULL);
        if (a->host->ensure_network(a->host->ctx) != 0) {
            error = "Нет сети. Проверьте Wi-Fi и нажмите «Войти» ещё раз.";
            continue;
        }
        char *token = NULL, *refresh = NULL;
        yb_auth_status st = yb_auth_exchange_code(YB_CLIENT_ID, code, verifier, &token, &refresh);
        if (st == YB_AUTH_OK) {
            yb_config_set(a->cfg, "token", token);
            if (refresh) yb_config_set(a->cfg, "refresh_token", refresh);
            free(token);
            free(refresh);
            if (yb_config_save(a->cfg) != 0)
                YB_WARN("login: could not save the token, next start will ask again");
            result = GO_BACK;
            break;
        }
        if (st == YB_AUTH_DENIED) {
            error = "Код не подошёл. Проверьте его и введите ещё раз.";
            code[0] = '\0';
        } else {
            error = "Сервер не ответил. Нажмите «Войти» ещё раз.";
        }
    }
    free(qr);
    return result;
}

/* --- library list --------------------------------------------------------- */

static void lib_free(lib_list *l) {
    for (size_t i = 0; i < l->count; ++i) {
        free(l->items[i].id);
        free(l->items[i].title);
        free(l->items[i].author);
    }
    free(l->items);
    memset(l, 0, sizeof(*l));
}

static int lib_add(lib_list *l, const char *id, const char *title, const char *author) {
    lib_item *grown = realloc(l->items, (l->count + 1) * sizeof(*grown));
    if (!grown) return -1;
    l->items = grown;
    lib_item *it = &l->items[l->count++];
    it->id = strdup(id);
    it->title = strdup(title);
    it->author = strdup(author);
    return 0;
}

static void write_field(FILE *f, const char *s, char end) {
    for (; s && *s; ++s) fputc((*s == '\t' || *s == '\n' || *s == '\r') ? ' ' : *s, f);
    fputc(end, f);
}

static void lib_save(const app *a, const lib_list *l) {
    char tmp[1040];
    snprintf(tmp, sizeof(tmp), "%s.tmp", a->library_path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    for (size_t i = 0; i < l->count; ++i) {
        write_field(f, l->items[i].id, '\t');
        write_field(f, l->items[i].title, '\t');
        write_field(f, l->items[i].author, '\n');
    }
    if (fclose(f) != 0 || rename(tmp, a->library_path) != 0) remove(tmp);
}

static void lib_load(const app *a, lib_list *l) {
    FILE *f = fopen(a->library_path, "r");
    if (!f) return;
    char line[4096];
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = '\0';
        char *title = strchr(line, '\t');
        if (!title) continue;
        *title++ = '\0';
        char *author = strchr(title, '\t');
        if (!author) continue;
        *author++ = '\0';
        if (yb_book_id_valid(line)) lib_add(l, line, title, author);
    }
    fclose(f);
}

/* Replaces `l` from the server. Returns 0, -1 for a network failure, or the
 * HTTP status. */
static int lib_fetch(app *a, lib_list *l) {
    if (a->host->ensure_network(a->host->ctx) != 0) return -1;
    yb_library lib;
    int rc = yb_api_get_my_library(yb_config_get(a->cfg, "token"), &lib);
    if (rc != 0) return rc;
    lib_list fresh = { 0 };
    for (size_t i = 0; i < lib.count; ++i) {
        const yb_book *b = &lib.items[i].book;
        if (!yb_book_id_valid(b->uuid)) continue;
        const char *author = b->author_count && b->authors[0].name ? b->authors[0].name : "";
        lib_add(&fresh, b->uuid, b->title ? b->title : "Без названия", author);
    }
    yb_library_free(&lib);
    lib_free(l);
    *l = fresh;
    lib_save(a, l);
    return 0;
}

/* --- reader --------------------------------------------------------------- */

typedef struct { app *a; } load_ctx;

static void on_chapter(void *ctx, size_t done, size_t total) {
    app *a = ((load_ctx *)ctx)->a;
    char text[96];
    snprintf(text, sizeof(text), "Глава %zu из %zu", done, total);
    a->host->keep_awake(a->host->ctx);
    show_message(a, "Загружаю книгу…", text);
}

static int font_px(app *a) {
    const char *v = yb_config_get(a->cfg, "font_px");
    int px = v ? atoi(v) : 0;
    return px > 0 ? px : a->c->dpi / 7;
}

typedef enum { MENU_RESUME, MENU_SMALLER, MENU_BIGGER, MENU_LIBRARY, MENU_EXIT, MENU_COUNT } menu_item;

static menu_item reader_menu(app *a) {
    static const char *const labels[MENU_COUNT] = {
        "Продолжить чтение", "Шрифт меньше", "Шрифт больше", "К библиотеке", "Выход",
    };
    yb_canvas *c = a->c;
    int m = c->w / 10;
    int bh = c->h / 10;
    int gap = bh / 4;
    int top = (c->h - MENU_COUNT * bh - (MENU_COUNT - 1) * gap) / 2;
    int full = 0;
    for (;;) {
        yb_canvas_clear(c, 0xFF);
        rect r[MENU_COUNT];
        for (int i = 0; i < MENU_COUNT; ++i) {
            r[i] = (rect){ m, top + i * (bh + gap), c->w - 2 * m, bh };
            button(a, r[i], labels[i]);
        }
        present(a, full);
        full = 0;
        yb_event ev;
        wait_event(a, &ev);
        if (ev.type == YB_EV_QUIT) return MENU_EXIT;
        if (ev.type == YB_EV_WAKE) { full = 1; continue; }
        if (ev.type != YB_EV_TAP) continue;
        for (int i = 0; i < MENU_COUNT; ++i)
            if (inside(r[i], ev.x, ev.y)) return (menu_item)i;
    }
}

static int open_document(app *a, const lib_item *book, yb_document *doc) {
    if (yb_book_cache_load(a->books_dir, book->id, doc) == 0) return 0;
    show_message(a, "Загружаю книгу…", book->title);
    if (a->host->ensure_network(a->host->ctx) != 0) {
        yb_document_init(doc);
        return show_error(a, "Нет сети",
                          "Эта книга ещё не скачана. Проверьте Wi-Fi и откройте её снова.") ? -1 : -2;
    }
    load_ctx ctx = { a };
    if (yb_content_load_book_ex(yb_config_get(a->cfg, "token"), book->id, doc,
                                on_chapter, &ctx) != 0) {
        return show_error(a, "Не удалось загрузить книгу",
                          "Возможны две причины: пропала сеть или это сериал, а сериалы "
                          "приложение пока не поддерживает.") ? -1 : -2;
    }
    if (!doc->title) yb_document_set_title(doc, book->title);
    if (yb_book_cache_save(a->books_dir, book->id, doc) != 0)
        YB_WARN("reader: book is open but not saved for offline reading");
    return 0;
}

static nav reader_screen(app *a, const lib_item *book) {
    yb_document doc;
    int opened = open_document(a, book, &doc);
    if (opened == -2) return GO_EXIT;
    if (opened != 0) return GO_BACK;

    yb_canvas *c = a->c;
    int px = font_px(a);
    int min_px = c->dpi / 12 > 12 ? c->dpi / 12 : 12;
    int max_px = c->dpi / 3 > 24 ? c->dpi / 3 : 24;
    int reserve = yb_font_line_height(a->small) * 3 / 2;

    yb_pos saved;
    yb_book_pos_load(a->books_dir, book->id, &saved);

    nav result = GO_BACK;
    yb_font *font = NULL;
    yb_page_index idx = { 0 };
    size_t page = 0;
    int rebuild = 1, full = 1, since_full = 0, draw = 1;

    for (;;) {
        if (rebuild) {
            show_message(a, "Подготовка страниц…", NULL);
            yb_font_free(font);
            yb_page_index_free(&idx);
            font = yb_font_load(a->paths->book_font, px);
            time_t started = time(NULL);
            if (!font || yb_page_index_build(&idx, font, c->w, c->h, &doc, reserve) != 0) {
                show_error(a, "Ошибка", "Не удалось подготовить страницы книги.");
                break;
            }
            YB_INFO("reader: %zu pages at %d px, counted in about %ld s",
                    idx.count, px, (long)(time(NULL) - started));
            page = yb_page_index_find(&idx, saved);
            rebuild = 0;
            full = 1;
            draw = 1;
        }
        if (draw) {
            yb_render_page_ex(font, c, c->w, c->h, &doc, idx.starts[page], reserve, NULL);
            char footer[64];
            snprintf(footer, sizeof(footer), "%zu из %zu", page + 1, idx.count);
            text_centered(a->small, c, (rect){ 0, c->h - reserve - c->dpi / 30, c->w, reserve }, footer);
            if (since_full >= FULL_REFRESH_EVERY) full = 1;
            present(a, full);
            since_full = full ? 0 : since_full + 1;
            full = 0;
            draw = 0;
        }

        yb_event ev;
        wait_event(a, &ev);
        int forward = 0, backward = 0;
        switch (ev.type) {
        case YB_EV_QUIT:
            result = GO_EXIT;
            goto done;
        case YB_EV_WAKE:
            full = 1;
            draw = 1;
            continue;
        case YB_EV_SWIPE_LEFT:
            forward = 1;
            break;
        case YB_EV_SWIPE_RIGHT:
            backward = 1;
            break;
        case YB_EV_TAP:
            if (ev.y < c->h / 8) {
                menu_item item = reader_menu(a);
                draw = 1;
                if (item == MENU_LIBRARY) goto done;
                if (item == MENU_EXIT) { result = GO_EXIT; goto done; }
                if (item == MENU_SMALLER || item == MENU_BIGGER) {
                    int next = px + (item == MENU_BIGGER ? c->dpi / 50 : -c->dpi / 50);
                    if (next >= min_px && next <= max_px) {
                        px = next;
                        char v[16];
                        snprintf(v, sizeof(v), "%d", px);
                        yb_config_set(a->cfg, "font_px", v);
                        yb_config_save(a->cfg);
                        saved = idx.starts[page];
                        rebuild = 1;
                    }
                }
                continue;
            }
            if (ev.x < c->w * 3 / 10) backward = 1;
            else forward = 1;
            break;
        case YB_EV_TIMEOUT:
            continue;
        }
        if (forward && page + 1 < idx.count) { page++; draw = 1; }
        if (backward && page > 0) { page--; draw = 1; }
        if (draw) yb_book_pos_save(a->books_dir, book->id, idx.starts[page]);
    }
done:
    if (idx.starts) yb_book_pos_save(a->books_dir, book->id, idx.starts[page]);
    yb_page_index_free(&idx);
    yb_font_free(font);
    yb_document_free(&doc);
    return result;
}

/* --- library screen ------------------------------------------------------- */

typedef struct {
    rect refresh, leave, prev, next;
    int rows_y, row_h;
} lib_layout;

static lib_layout lib_geometry(const app *a) {
    lib_layout l;
    int w = a->c->w, h = a->c->h;
    int m = w / 30;
    int bar = h / 13;
    int bw = w / 4;
    l.leave = (rect){ w - m - bw, m, bw, bar };
    l.refresh = (rect){ l.leave.x - m / 2 - bw, m, bw, bar };
    l.prev = (rect){ m, h - m - bar, bw, bar };
    l.next = (rect){ w - m - bw, h - m - bar, bw, bar };
    l.rows_y = m + bar + m / 2;
    l.row_h = (l.prev.y - m / 2 - l.rows_y) / LIB_ROWS;
    return l;
}

static void draw_library(app *a, const lib_layout *l, const lib_list *lib, size_t first) {
    yb_canvas *c = a->c;
    yb_canvas_clear(c, 0xFF);
    int m = c->w / 30;
    yb_font_draw_text(a->ui, c, m,
                      l->refresh.y + (l->refresh.h - yb_font_line_height(a->ui)) / 2 + yb_font_ascender(a->ui),
                      "Книги");
    button(a, l->refresh, "Обновить");
    button(a, l->leave, "Выход");

    char buf[512];
    for (size_t i = 0; i < LIB_ROWS && first + i < lib->count; ++i) {
        const lib_item *it = &lib->items[first + i];
        int y = l->rows_y + (int)i * l->row_h;
        int text_w = c->w - 2 * m;
        int downloaded = yb_book_cache_exists(a->books_dir, it->id);
        if (downloaded) {
            text_w -= c->dpi / 5;
            yb_font_draw_text(a->ui, c, c->w - m - c->dpi / 6,
                              y + l->row_h / 2, "✓");
        }
        fit_text(a->ui, it->title, text_w, buf, sizeof(buf));
        yb_font_draw_text(a->ui, c, m, y + l->row_h / 2 - yb_font_line_height(a->small) / 4, buf);
        fit_text(a->small, it->author, text_w, buf, sizeof(buf));
        yb_font_draw_text(a->small, c, m, y + l->row_h / 2 + yb_font_line_height(a->small), buf);
        fill(c, (rect){ m, y + l->row_h - 1, c->w - 2 * m, 1 }, 0x80);
    }

    size_t pages = (lib->count + LIB_ROWS - 1) / LIB_ROWS;
    if (pages > 1) {
        if (first > 0) button(a, l->prev, "Назад");
        if (first + LIB_ROWS < lib->count) button(a, l->next, "Вперёд");
        char footer[48];
        snprintf(footer, sizeof(footer), "%zu из %zu", first / LIB_ROWS + 1, pages);
        text_centered(a->small, c, (rect){ l->prev.x + l->prev.w, l->prev.y,
                                           l->next.x - l->prev.x - l->prev.w, l->prev.h }, footer);
    }
}

/* Returns 0, or GO_EXIT/GO_LOGIN (after showing the reason) as a navigation. */
static int refresh_library(app *a, lib_list *lib, nav *to) {
    show_message(a, "Обновляю список книг…", NULL);
    int rc = lib_fetch(a, lib);
    if (rc == 0) return 0;
    if (rc == 401 || rc == 403) {
        *to = GO_LOGIN;
        return -1;
    }
    char msg[160];
    if (rc < 0) snprintf(msg, sizeof(msg), "Нет связи с сервером. Проверьте Wi-Fi и нажмите «Обновить».");
    else snprintf(msg, sizeof(msg), "Сервер вернул ошибку %d. Попробуйте позже.", rc);
    if (!show_error(a, "Список не обновлён", msg)) {
        *to = GO_EXIT;
        return -1;
    }
    return 0;
}

static nav library_screen(app *a) {
    lib_list lib = { 0 };
    lib_load(a, &lib);
    nav result = GO_EXIT;
    if (lib.count == 0 && refresh_library(a, &lib, &result) != 0) goto out;

    lib_layout l = lib_geometry(a);
    size_t first = 0;
    int full = 1;
    for (;;) {
        draw_library(a, &l, &lib, first);
        present(a, full);
        full = 0;

        yb_event ev;
        wait_event(a, &ev);
        if (ev.type == YB_EV_QUIT) { result = GO_EXIT; break; }
        if (ev.type == YB_EV_WAKE) { full = 1; continue; }

        int next = ev.type == YB_EV_SWIPE_LEFT, prev = ev.type == YB_EV_SWIPE_RIGHT;
        if (ev.type == YB_EV_TAP) {
            if (inside(l.leave, ev.x, ev.y)) { result = GO_EXIT; break; }
            if (inside(l.refresh, ev.x, ev.y)) {
                if (refresh_library(a, &lib, &result) != 0) break;
                first = 0;
                continue;
            }
            next = inside(l.next, ev.x, ev.y);
            prev = inside(l.prev, ev.x, ev.y);
            int row = (ev.y - l.rows_y) / l.row_h;
            if (!next && !prev && ev.y >= l.rows_y && row < LIB_ROWS &&
                first + (size_t)row < lib.count) {
                nav to = reader_screen(a, &lib.items[first + (size_t)row]);
                if (to != GO_BACK) { result = to; break; }
                full = 1;
                continue;
            }
        }
        if (next && first + LIB_ROWS < lib.count) first += LIB_ROWS;
        if (prev && first >= LIB_ROWS) first -= LIB_ROWS;
    }
out:
    lib_free(&lib);
    return result;
}

/* --- entry point ---------------------------------------------------------- */

int yb_app_run(yb_host *host, yb_canvas *canvas, const yb_app_paths *paths) {
    app a = { .host = host, .c = canvas, .paths = paths };
    snprintf(a.books_dir, sizeof(a.books_dir), "%s/books", paths->data_dir);
    snprintf(a.library_path, sizeof(a.library_path), "%s/library.tsv", paths->data_dir);
    yb_mkdir_p(a.books_dir);

    int ui_px = canvas->w / 33, small_px = canvas->w / 42;
    a.ui = yb_font_load(paths->ui_font, ui_px);
    a.small = yb_font_load(paths->ui_font, small_px);
    a.cfg = yb_config_open();
    int rc = 1;
    if (a.ui && a.small && a.cfg) {
        rc = 0;
        for (;;) {
            const char *token = yb_config_get(a.cfg, "token");
            if ((!token || !*token) && login_screen(&a) != GO_BACK) break;
            nav to = library_screen(&a);
            if (to != GO_LOGIN) break;
            /* The server rejected the token: drop it and ask again. */
            yb_config_set(a.cfg, "token", "");
            yb_config_save(a.cfg);
        }
    }
    yb_config_free(a.cfg);
    yb_font_free(a.small);
    yb_font_free(a.ui);
    return rc;
}
