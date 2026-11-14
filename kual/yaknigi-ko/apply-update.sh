#!/bin/sh
# Puts a downloaded version of the plugin in place, before KOReader reads it, and takes it back
# if the last start with it never reported success. A new version of the plugin brings a new one
# of this file too, but it has to work whatever the plugin has become.
DIR=${YAKNIGI_DIR:-/mnt/us/extensions/yaknigi-ko}
UPDATE=${KO_HOME:-$DIR/home}/yaknigi/update
PLUGIN=$DIR/koreader/plugins/yaknigi.koplugin
PREVIOUS=$UPDATE/previous.koplugin

# Stopped between the two moves below.
if [ ! -d "$PLUGIN" ] && [ -d "$PREVIOUS" ]; then
    mv "$PREVIOUS" "$PLUGIN"
fi

if [ -f "$UPDATE/trial" ]; then
    if [ -d "$PREVIOUS" ]; then
        cp "$UPDATE/trial" "$UPDATE/bad"
        rm -rf "$UPDATE/broken.koplugin"
        mv "$PLUGIN" "$UPDATE/broken.koplugin" && mv "$PREVIOUS" "$PLUGIN"
        rm -rf "$UPDATE/broken.koplugin"
    fi
    rm -f "$UPDATE/trial"
    sync
fi

[ -f "$UPDATE/pending/ready" ] || exit 0

# True when version $1 is later than version $2.
later() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if (x[i] + 0 > y[i] + 0) exit 0
            if (x[i] + 0 < y[i] + 0) exit 1
        }
        exit 1
    }'
}

NEW=$(cat "$UPDATE/pending/ready")
OLD=$(cat "$PLUGIN/yaknigi/VERSION" 2>/dev/null)
# Installed by hand meanwhile: what waits here may be older than what is there now.
if [ -z "$NEW" ] || ! [ -d "$UPDATE/pending/yaknigi.koplugin" ] || ! later "$NEW" "${OLD:-0}"; then
    rm -rf "$UPDATE/pending"
    exit 0
fi

rm -rf "$PREVIOUS"
mv "$PLUGIN" "$PREVIOUS" || exit 0
# Before the new one is in place, so that no start of it can go without the rollback above.
printf '%s' "$NEW" > "$UPDATE/trial"
if ! mv "$UPDATE/pending/yaknigi.koplugin" "$PLUGIN"; then
    mv "$PREVIOUS" "$PLUGIN"
    rm -f "$UPDATE/trial"
    exit 0
fi
rm -rf "$UPDATE/pending"
sync
exit 0
