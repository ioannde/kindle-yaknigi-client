project('kindle-yaknigi', 'c',
  version : '0.1.0',
  default_options : [
    'c_std=c11',
    'warning_level=2',
    'werror=false',
  ],
)

add_project_arguments('-D_GNU_SOURCE', language : 'c')

cc = meson.get_compiler('c')

# --- dependencies -----------------------------------------------------------
# On the host these come from the system; on the Kindle cross build they are
# statically linked from third_party/ (see PLAN.md 5, docs/STRUCTURE.md).
libcurl_dep  = dependency('libcurl')
cjson_dep    = dependency('libcjson')
zlib_dep     = dependency('zlib')
freetype_dep = dependency('freetype2')
crypto_dep   = dependency('libcrypto')   # AES-256-CBC for the Bookmate manifest
libm_dep     = cc.find_library('m', required : false)

inc = include_directories('src')

# --- core library -----------------------------------------------------------
# Everything hardware-independent: net, Yandex API client, storage, and the
# reader engine (works on any EPUB, independent of how it was fetched).
core_sources = files(
  'src/util/log.c',
  'src/util/buf.c',
  'src/util/url.c',
  'src/util/base64.c',
  'src/platform/net.c',
  'src/yandex/json.c',
  'src/yandex/models.c',
  'src/yandex/auth.c',
  'src/yandex/api.c',
  'src/yandex/crypto.c',
  'src/yandex/content.c',
  'src/storage/config.c',
  'src/reader/zip.c',
  'src/reader/html.c',
  'src/reader/opf.c',
  'src/reader/epub.c',
  'src/reader/document.c',
  'src/reader/layout.c',
  'src/reader/render.c',
  'src/reader/pages.c',
  'src/platform/display.c',
  'src/storage/book_cache.c',
  'src/app/app.c',
  'src/third_party/qrcodegen.c',
)

yb_deps = [libcurl_dep, cjson_dep, zlib_dep, freetype_dep, crypto_dep, libm_dep]

libyb = static_library('yb', core_sources,
  include_directories : inc,
  dependencies : yb_deps,
)

yb_dep = declare_dependency(
  link_with : libyb,
  include_directories : inc,
  dependencies : yb_deps,
)

# --- tools ------------------------------------------------------------------
# smoke: real network path — device-flow login + list library.
executable('yb-smoke', 'src/tools/smoke.c',
  dependencies : yb_dep,
  install : false,
)

# render: real reader path — turn a local .epub into page images (PGM).
executable('yb-render', 'src/tools/render.c',
  dependencies : yb_dep,
  install : false,
)

# sim: runs the whole app on the host with scripted input, saving each screen.
executable('yb-sim', 'src/tools/sim.c',
  dependencies : yb_dep,
  install : false,
)

# probe: first on-device check of the screen, touch input and HTTPS.
if get_option('kindle')
  executable('yb-probe',
    'src/tools/probe.c',
    'src/platform/display_fbink.c',
    'src/platform/input_evdev.c',
    dependencies : [yb_dep, dependency('fbink')],
    install : false,
  )
  executable('yb-app',
    'src/app/main_kindle.c',
    'src/platform/display_fbink.c',
    'src/platform/input_evdev.c',
    dependencies : [yb_dep, dependency('fbink')],
    install : false,
  )
endif

# --- tests ------------------------------------------------------------------
test_inc = include_directories('src', 'tests')

foreach t : ['test_buf', 'test_url', 'test_models', 'test_zip', 'test_layout', 'test_base64', 'test_opf', 'test_crypto', 'test_epub', 'test_pkce', 'test_pages', 'test_book_cache']
  exe = executable(t, 'tests/' + t + '.c',
    include_directories : test_inc,
    dependencies : yb_dep,
  )
  test(t, exe)
endforeach
