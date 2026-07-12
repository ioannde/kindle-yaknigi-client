# kindle-yaknigi

Автономный нативный клиент **Яндекс Книг** для Amazon Kindle (e-ink).
Диапазон устройств: **Kindle Touch → Paperwhite 2022** (ведущее — PW5).
Архитектура, решения и дорожная карта: [`PLAN.md`](PLAN.md),
[`docs/STRUCTURE.md`](docs/STRUCTURE.md), [`docs/PHASE0.md`](docs/PHASE0.md).

## Статус реализации

Рабочий (не заглушки), собирается и покрыт тестами на хосте:

| Модуль | Что делает | Состояние |
|---|---|---|
| `platform/net` | HTTP(S) поверх libcurl (свой CA-бандл на устройстве) | ✅ рабочий |
| `yandex/auth` | OAuth **device flow** + `test_token` | ✅ рабочий |
| `yandex/api` | `get_my_library`, `get_book` (REST + разбор JSON) | ✅ рабочий¹ |
| `yandex/models`, `json` | Book / LibraryCard / User + парсинг | ✅ + юнит-тесты |
| `storage/config` | токен, device_id, настройки (файл) | ✅ рабочий |
| `reader/zip` | ZIP-ридер на zlib (для EPUB) | ✅ + юнит-тест |
| `reader/epub` | EPUB → текст (OPF, spine, XHTML→блоки, сущности) | ✅ рабочий |
| `reader/layout` | перенос строк / пагинация | ✅ + юнит-тест |
| `reader/render` | FreeType → страницы на grayscale-канве | ✅ рабочий |
| `platform/display` | grayscale-канва + вывод PGM (хост) | ✅ рабочий |
| `yandex/crypto` | AES-256-CBC (OpenSSL) для манифеста | ✅ + тест-вектор |
| `yandex/content` | **протокол чтения Bookmate** | ✅ реализован² |

¹ Базовый URL/пути REST подтверждены в Фазе 0 (`Auth-Token` + App-заголовки);
override через `YB_API_BASE`.
² Фаза 0 пройдена (🟢): протокол чтения снят с приложения
([`docs/PHASE0-FINDINGS.md`](docs/PHASE0-FINDINGS.md)). `content.c`:
`metadata/v4` → `metadata_secret` (ключ) → **AES-256-CBC** дешифровка `opf` →
spine → `/documents/{doc}/content?path=…` (plain HTML) → общий `html→blocks`.
Дешифровка проверена тест-вектором, парсинг главы — на реальном HTML Bookmate.
Живой end-to-end прогоняется под токеном: `yb-smoke read <book_uuid>`.

## Инструменты

- **`yb-render <book.epub> <out-dir> [max-pages]`** — полный конвейер чтения:
  ZIP → EPUB → текст → пагинация → FreeType → изображения страниц (PGM).
  Ничего от Яндекса не требует; доказывает движок чтения на реальных книгах.
- **`yb-smoke [login|library|whoami|read UUID]`** — реальный сетевой путь:
  device-flow логин, вывод библиотеки, и `read <uuid>` — загрузка текста книги
  через протокол чтения Bookmate (метаданные → дешифровка → главы).
- **`tools/download_epub.py <uuid>`** — Python-утилита: качает книгу и
  пересобирает её в стандартный **`.epub`** (метаданные → AES-дешифровка
  манифеста → все главы/картинки/css → упаковка). Только свои легальные книги.

## Сборка (хост)

Зависимости: `meson`, `ninja`, `gcc`, `libcurl`, `libcjson`, `zlib`,
`freetype2`.

```sh
meson setup build
ninja -C build
meson test -C build          # юнит-тесты
```

Пример рендера:

```sh
./build/yb-render book.epub /tmp/pages 5
# → /tmp/pages/page-001.pgm ...  (1236×1648, экран PW5)
```

Переменные окружения: `YB_FONT`, `YB_FONT_PX`, `YB_SCREEN_W/H/DPI`,
`YB_API_BASE`, `YB_CA_BUNDLE`, `YANDEX_CLIENT_ID`, `YANDEX_CLIENT_SECRET`,
`YANDEX_TOKEN`, `YB_LOG` (error|warn|info|debug).

## Кросс-сборка под Kindle

Шаблоны cross-файлов: [`cross/pw5.txt`](cross/pw5.txt) (PW5 и новые),
[`cross/kindle-touch.txt`](cross/kindle-touch.txt) (нижняя граница, Фаза 5).
Заполнить пути тулчейна и запускать `meson setup build-pw5 --cross-file
cross/pw5.txt`. Тяжёлые зависимости на устройстве линкуются статически.
