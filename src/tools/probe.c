/* yb-probe: first on-device check. Runs the real rendering path to the panel,
 * reads touches and makes one HTTPS request without any token. Every result
 * goes to stdout, which run.sh saves as probe.log. */
#include "platform/display_fbink.h"
#include "platform/input_evdev.h"
#include "platform/net.h"
#include "reader/document.h"
#include "reader/render.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PROBE_URL "https://api.bookmate.yandex.net/api/v5/"
#define TAP_COUNT 3
#define TAP_TIMEOUT_MS 30000
#define WATCHDOG_SECONDS 240 /* the kernel releases the screen and touch if we hang */
#define MAX_LINES 16

static const char *lines[MAX_LINES];
static char line_buf[MAX_LINES][160];
static int line_count;

static yb_display *display;
static yb_canvas *canvas;
static yb_font *font;

static void say(const char *fmt, const char *arg, int a, int b) {
    if (line_count == MAX_LINES) return;
    snprintf(line_buf[line_count], sizeof(line_buf[0]), fmt, arg ? arg : "", a, b);
    lines[line_count] = line_buf[line_count];
    printf("%s\n", lines[line_count]);
    fflush(stdout);
    line_count++;
}

static void show(int full) {
    yb_document doc;
    yb_document_init(&doc);
    for (int i = 0; i < line_count; ++i) yb_document_add(&doc, 0, lines[i]);
    yb_pos start = { 0, 0 };
    int done = 0;
    yb_render_page(font, canvas, &doc, start, &done);
    yb_display_present(display, canvas, full);
    yb_document_free(&doc);
}

static void check_touch(void) {
    yb_touch *touch = yb_touch_open();
    if (!touch) {
        say("Тач: устройство не найдено%s", "", 0, 0);
        show(0);
        return;
    }
    int max_x, max_y;
    yb_touch_range(touch, &max_x, &max_y);
    say("%sКоснитесь экрана %d раза: левый верх, правый верх, левый низ.", "", TAP_COUNT, 0);
    show(0);
    for (int i = 0; i < TAP_COUNT; ++i) {
        int x = 0, y = 0;
        int rc = yb_touch_wait_tap(touch, TAP_TIMEOUT_MS, &x, &y);
        if (rc == 1) {
            printf("tap %d raw=%d,%d range=%dx%d\n", i + 1, x, y, max_x, max_y);
            say("%sКасание: %d, %d", "", x, y);
        } else {
            say(rc == 0 ? "%sТач: касания не было" : "%sТач: ошибка чтения", "", 0, 0);
            show(0);
            break;
        }
        show(0);
    }
    yb_touch_close(touch);
}

static void check_https(void) {
    say("Проверяю HTTPS%s", "", 0, 0);
    show(0);
    yb_net_global_init();
    yb_http_response resp;
    if (yb_http_request("GET", PROBE_URL, NULL, NULL, NULL, 0, &resp) == 0) {
        say("%sHTTPS работает, ответ сервера: %d", "", (int)resp.status, 0);
        yb_http_response_free(&resp);
    } else {
        say("HTTPS не работает: проверьте Wi-Fi, детали в probe.log%s", "", 0, 0);
    }
    yb_net_global_cleanup();
    show(0);
}

int main(void) {
    alarm(WATCHDOG_SECONDS);

    const char *font_path = getenv("YB_FONT");
    if (!font_path) font_path = "DejaVuSans.ttf";

    display = yb_display_open();
    if (!display) return 1;
    char info[192];
    yb_display_describe(display, info, sizeof(info));
    printf("%s\n", info);

    int dpi = yb_display_dpi(display);
    font = yb_font_load(font_path, dpi > 0 ? dpi / 7 : 40);
    canvas = yb_canvas_new(yb_display_width(display), yb_display_height(display), dpi);
    if (!font || !canvas) {
        fprintf(stderr, "error: cannot load font %s or allocate the canvas\n", font_path);
        return 1;
    }

    say("Yaknigi: проверка устройства. Если текст читается, экран работает.%s", "", 0, 0);
    show(1);
    check_touch();
    check_https();
    say("Готово, результаты в probe.log. Возврат на главный экран через 8 секунд.%s", "", 0, 0);
    show(0);
    sleep(8);

    yb_font_free(font);
    yb_canvas_free(canvas);
    yb_display_close(display);
    return 0;
}
