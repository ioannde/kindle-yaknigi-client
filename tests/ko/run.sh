#!/bin/sh
# Runs KOReader for Linux with the plugin and the test driver, against the mock server.
# Usage: run.sh KOREADER_DIR OUT_DIR
set -u
KO=$1
OUT=$2
REPO=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
PORT=18765
HOME_DIR=$OUT/ko-home
mkdir -p "$OUT/empty" "$HOME_DIR/settings"

cp -R "$REPO/koreader/yaknigi.koplugin" "$KO/plugins/"
cp -R "$REPO/tests/ko/yaknigi_test.koplugin" "$KO/plugins/"
cp "$REPO/koreader/settings.reader.lua" "$HOME_DIR/settings.reader.lua"

python3 "$REPO/tools/mock/server.py" "$PORT" koreader &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

cd "$KO" || exit 2
KO_HOME=$HOME_DIR YAKNIGI_APP=1 YAKNIGI_TEST_OUT=$OUT \
    YB_API_BASE=http://127.0.0.1:$PORT/api/v5 YB_OAUTH_BASE=http://127.0.0.1:$PORT \
    EMULATE_READER_W=1236 EMULATE_READER_H=1648 EMULATE_READER_DPI=300 \
    SDL_AUDIODRIVER=dummy \
    timeout 300 xvfb-run -a -s "-screen 0 1236x1648x24" ./luajit reader.lua -d "$OUT/empty" 2>&1 \
    | tee "$OUT/koreader.log" | grep -E '\[driver\]|Traceback|attempt to|error' 
test -f "$OUT/PASS"
