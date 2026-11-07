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
# The emulated screen is colour, which KOReader asks about once; a Paperwhite's is not.
sed 's/^}$/    ["color_rendering"] = false,\n}/' "$REPO/koreader/settings.reader.lua" > "$HOME_DIR/settings.reader.lua"

python3 "$REPO/tools/mock/server.py" "$PORT" koreader &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

cd "$KO" || exit 2
{
    KO_HOME=$HOME_DIR YAKNIGI_APP=1 YAKNIGI_TEST_OUT=$OUT \
        YB_API_BASE=http://127.0.0.1:$PORT/api/v5 YB_OAUTH_BASE=http://127.0.0.1:$PORT \
        YB_GRAPHQL_URL=http://127.0.0.1:$PORT/graphql YB_CLIENT_ID=test-client \
        EMULATE_READER_W=1236 EMULATE_READER_H=1648 EMULATE_READER_DPI=300 \
        SDL_AUDIODRIVER=dummy \
        timeout 300 xvfb-run -a -s "-screen 0 1236x1648x24" ./luajit reader.lua -d "$OUT/empty" 2>&1
    echo $? > "$OUT/status"
} | tee "$OUT/koreader.log" | grep -E '\[driver\]|Traceback|attempt to|error'
STATUS=$(cat "$OUT/status")
# The script's last step closes the app, so running into the time limit means it did not end.
if [ "$STATUS" = 124 ]; then
    echo "the app did not end when asked to" >&2
    exit 1
fi
test -f "$OUT/PASS"
