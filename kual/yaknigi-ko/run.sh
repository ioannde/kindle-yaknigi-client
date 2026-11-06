#!/bin/sh
# Starts KOReader with the Yandex plugin, with its own settings and books.
DIR=/mnt/us/extensions/yaknigi-ko
export KO_HOME="$DIR/home"
export YAKNIGI_APP=1
mkdir -p "$KO_HOME"
[ -f "$KO_HOME/settings.reader.lua" ] || cp "$DIR/settings.reader.lua" "$KO_HOME/settings.reader.lua"
exec "$DIR/koreader/koreader.sh" --kual
