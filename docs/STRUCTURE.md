# Структура проекта (C, нативное приложение)

Модульная структура отражает решения из `PLAN.md`: автономный клиент на C,
кросс-сборка Meson под диапазон **Kindle Touch → PW2022**, тач-first ввод
(+ кнопки Oasis), свой сетевой стек, свой ридер. Главный принцип —
**платформенные абстракции**: только слой `platform/` знает про конкретное
железо; всё остальное (UI, ридер, API-клиент) работает поверх интерфейсов и
переносимо между моделями.

---

## Дерево каталогов

```
kindle_yaknigi/
├─ meson.build                # корневая сборка
├─ cross/
│  ├─ pw5.txt                 # cross-file: новые модели (новый glibc)
│  └─ kindle-touch.txt        # cross-file: старый glibc (Фаза 5)
├─ third_party/               # вендоринг, статическая линковка
│  ├─ curl/ mbedtls/          # сеть + TLS
│  ├─ cjson/                  # JSON
│  ├─ freetype/               # шрифты
│  ├─ miniz/                  # zip (EPUB)
│  └─ qrcodegen/              # QR для device flow
├─ assets/
│  ├─ fonts/                  # встроенные TTF
│  └─ cacert.pem              # актуальный CA-бандл
├─ kual/                      # KUAL-расширение (menu.json + launcher)
├─ src/
│  ├─ main.c                  # entry point, инициализация, главный цикл
│  ├─ app/                    # оркестрация экранов и состояния
│  ├─ platform/               # ЕДИНСТВЕННЫЙ слой, знающий железо
│  ├─ yandex/                 # клиент API Яндекс Книг (порт с Python)
│  ├─ reader/                 # движок чтения (парсинг + вёрстка + рендер)
│  ├─ ui/                     # примитивы UI поверх platform/display
│  ├─ storage/                # локальное хранилище (кэш/конфиг/прогресс)
│  └─ util/                   # log, память, строки
└─ tests/                     # хостовые юнит-тесты
```

---

## Слои и модули

### `platform/` — аппаратные абстракции
Изолирует всё различие между моделями. Реализации выбираются в рантайме по
определённой модели (`device.c`).

- `device.{c,h}` — определение модели, разрешение, dpi, наличие кнопок Oasis,
  ориентация.
- `display.h` + `display_fb.c` / `display_eips.c` — интерфейс дисплея:
  `dimensions(w,h,dpi)`, доступ к буферу, `present(rect, mode)` с
  **partial/full refresh**, поворот.
- `input.h` + `input_touch.c` / `input_oasis_keys.c` — ввод как **логические
  события** (см. ниже). Тач-бэкенд обслуживает capacitive и ИК-тач; бэкенд
  Oasis добавляет аппаратные кнопки листания и учитывает авто-поворот.
- `net.{c,h}` — HTTP(S) поверх **своего** `libcurl`+`mbedTLS`+`cacert.pem`:
  GET/POST, заголовки, **потоковый колбэк** (для стрима глав книги без загрузки
  целиком в RAM).

```c
// platform/input.h — контракт для всего UI
typedef enum {
    EV_TAP,        // x,y — по элементу
    EV_SELECT, EV_BACK,
    EV_PAGE_NEXT, EV_PAGE_PREV,   // края экрана ИЛИ кнопки Oasis
    EV_MENU
} ev_kind;
typedef struct { ev_kind kind; int x, y; } ui_event;
bool input_poll(ui_event *out);   // одинаково на всех моделях
```

### `yandex/` — клиент API (порт нужного подмножества `yandex-book-api`)
Python-библиотека — спецификация; здесь её эндпоинты на C.

- `auth.{c,h}` — **OAuth device flow** (`/device/code` → опрос `/token`),
  хранение токена, `test_token`; работает под **своим `client_id`**.
- `api.{c,h}` — REST: `get_my_library` (пагинация), `get_my_bookshelves`,
  `get_book`, `add_book`/`remove_book`, `get_profile`, прогресс/`sync_state`.
- `search.{c,h}` — **GraphQL** поиск (формат уточняется в Фазе 0).
- `content.{c,h}` — **протокол чтения** (по итогам Фазы 0): манифест книги →
  стрим глав → расшифровка → отдача в `reader/`. Самый рискованный модуль.
- `models.{c,h}` — Book, LibraryCard(progress,state), User, Bookshelf, Image.
- `json.{c,h}` — обёртки над cJSON (парсинг ответов в модели).

### `reader/` — движок чтения (ядро продукта)
Работает потоково — не держит книгу целиком в RAM (важно для 256 МБ на
Kindle Touch).

- `epub.{c,h}` — распаковка zip (miniz) + разбор XHTML/FB2.
- `document.{c,h}` — внутренняя модель: главы → блоки (абзацы, заголовки).
- `layout.{c,h}` — перенос строк и **пагинация под реальный размер экрана/dpi**
  (независимо от разрешения); ленивое вычисление страниц.
- `render_text.{c,h}` — растеризация страницы через **FreeType** в буфер дисплея.
- `position.{c,h}` — позиция чтения и прогресс %, отдаётся в `storage`/синк.

### `ui/` — примитивы интерфейса (поверх `platform/display`)
- `widget.{c,h}` — список, кнопка, текст, картинка; **тач-first** (тап = выбор,
  края = листание), те же события с кнопок Oasis.
- `image.{c,h}` — обложки, **dithering** в 16 градаций серого.
- `qr.{c,h}` — QR-код страницы подтверждения для device flow (qrcodegen).
- `theme.{c,h}` — шрифты/отступы/контраст, **масштаб от dpi** (167 … 300).

### `app/` — оркестрация
- `app.{c,h}` — состояние, роутинг экранов, главный цикл (poll ввода → обновить
  → present).
- `screen_login.c` (device flow), `screen_library.c`, `screen_book.c`,
  `screen_reader.c`, `screen_search.c`.

### `storage/` — локальное хранилище
- `cache.{c,h}` — метаданные, обложки, собранные книги.
- `config.{c,h}` — токен, настройки.
- `progress_store.{c,h}` — позиции чтения + **очередь синка** в Яндекс
  (правило «последний по времени выигрывает»).

### `util/` — общее
- `log`, аллокации, строки, безопасные обёртки.

---

## Зависимости между слоями (сверху вниз)

```
app  ──▶ ui ──▶ platform/display
 │       └────▶ reader ──▶ platform/net (стрим глав)
 │       │        └──────▶ yandex/content
 ├──────▶ yandex/{auth,api,search} ──▶ platform/net
 ├──────▶ storage
 └──────▶ platform/{input,display,device}
```

Правила:
- `platform/` **ни от чего** внутри `src/` не зависит (только libc + third_party).
- `reader/`, `yandex/`, `ui/`, `storage/` **не знают про модель устройства** —
  только про интерфейсы `platform/`.
- Смена модели (PW5 → Kindle Touch/Oasis) = другой набор реализаций в
  `platform/` + другой cross-file. Остальной код не меняется.

---

## Сборка (Meson)

- Один код, два cross-file: `cross/pw5.txt` (MVP) и `cross/kindle-touch.txt`
  (Фаза 5, старый glibc). При необходимости — промежуточные для других моделей.
- Все тяжёлые зависимости из `third_party/` линкуются **статически** →
  независимость от системных библиотек устройства.
- `tests/` собираются под **хост** (не устройство): юнит-тесты для `layout`,
  `epub`, `json`, `models`, `position` — то, что не требует железа.

---

## Порядок реализации по фазам (из PLAN.md)

| Фаза | Модули |
|---|---|
| 1 — Каркас | `main`, `platform/*`, `net`, `yandex/auth` (device flow), `ui` базовое |
| 2 — Данные | `yandex/{api,search,models,json}`, `storage/cache`, экраны библиотека/поиск/книга |
| 3 — Ридер | `yandex/content`, `reader/*`, `screen_reader`, `storage/progress_store` |
| 4 — Полировка | офлайн-кэш, `ui/image` (dithering), память, стабилизация на PW2022 |
| 5 — Порт | `cross/kindle-touch.txt`, `input_oasis_keys`, проверка ИК-тача/TLS/256 МБ/600×800 |
