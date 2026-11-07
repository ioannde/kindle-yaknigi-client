#!/bin/sh
# Starts KOReader with the Yandex plugin, with its own settings and books.
DIR=/mnt/us/extensions/yaknigi-ko
export KO_HOME="$DIR/home"
export YAKNIGI_APP=1
mkdir -p "$KO_HOME"
# A new version of the seed replaces KOReader's settings. Sign-in and books are kept apart.
if ! cmp -s "$DIR/settings.reader.lua" "$KO_HOME/settings.seed"; then
    cp "$DIR/settings.reader.lua" "$KO_HOME/settings.reader.lua"
    cp "$DIR/settings.reader.lua" "$KO_HOME/settings.seed"
fi
# From KUAL there is nothing to say; a scriptlet says what suits it.
[ $# -gt 0 ] || set -- --kual
exec "$DIR/koreader/koreader.sh" "$@"
