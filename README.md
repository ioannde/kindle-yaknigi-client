# Клиент для Яндекс Книг

Неофициальный клиент **Яндекс Книг** для Amazon Kindle с джейлбрейком: плагин
`koreader/yaknigi.koplugin` к KOReader со своим простым интерфейсом.

## Установка

Сборка `yaknigi-ko-kindlehf` из GitHub Actions подходит для прошивок с hard-float
(`kindlehf`, 5.16.3 и новее). Её содержимое копируется в корень Kindle по USB.

- **С KUAL:** запуск из меню KUAL, пункт «Клиент для Яндекс Книг».
- **Без KUAL, с новыми джейлбрейками:** `documents/yaknigi.sh` виден среди книг
  как «Клиент для Яндекс Книг» и запускается по нажатию.
- **KPM:** сборка `yaknigi-ko-kpkg` содержит пакет `.kpkg` с той же программой.

Настройки, вход и скачанные книги лежат в `extensions/yaknigi-ko/home` и при
обновлении не трогаются.

О новых версиях программа спрашивает сама: раз в сутки при подключении к интернету она
смотрит в [релизы](https://github.com/ioannde/kindle-yaknigi-client/releases) и предлагает
обновиться, напомнить позже или пропустить эту версию. Если новая версия не запустится,
вернётся прежняя. Проверку можно отключить в настройках, раздел «О программе». Вручную
нужно поставить только версию, которая меняет KOReader или файлы запуска: программа об
этом скажет.

Пользуясь программой, вы принимаете [условия использования](koreader/yaknigi.koplugin/TERMS.md).

## Выпуск версии

Тег `vX.Y.Z` на `main` собирает программу и публикует релиз. Номер должен быть больше
прежнего, иначе обновление никому не придёт.

## Своя сборка

Идентификатор приложения Яндекса в репозитории не хранится. Зарегистрируйте своё
приложение на [oauth.yandex.ru](https://oauth.yandex.ru) (без секрета, вход по коду,
Redirect URI `https://oauth.yandex.ru/verification_code`) и задайте его Client ID в
секрете GitHub Actions `YANDEX_CLIENT_ID`. Сборка без него останавливается с ошибкой.
При запуске без сборки идентификатор берётся из переменной окружения `YB_CLIENT_ID`
или файла `yaknigi/client_id.lua` с содержимым `return "..."`.

## Прежний клиент на C

Всё, что ниже, описывает первую версию из `src/`: её заменил плагин. Архитектура:
[`PLAN.md`](PLAN.md), [`docs/STRUCTURE.md`](docs/STRUCTURE.md).

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
² Фаза 0 пройдена (🟢): протокол чтения снят с приложения. `content.c`:
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
