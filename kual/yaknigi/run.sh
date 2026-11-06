#!/bin/sh
# Starts the app with the Kindle UI paused, and always gives the UI back.
DIR=/mnt/us/extensions/yaknigi
LOCK=/tmp/yaknigi.lock
BIN=/tmp/yb-app

# A second tap in KUAL must not start a second copy. A lock left behind by a
# killed run does not count.
if ! mkdir "$LOCK" 2>/dev/null; then
    if kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCK/pid"

has_volumd() {
    [ -e /etc/init.d/volumd ] || [ -e /etc/upstart/volumd.conf ]
}

restore() {
    trap - EXIT INT TERM HUP
    has_volumd && killall -CONT volumd 2>/dev/null
    killall -CONT awesome 2>/dev/null
    lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
    rm -f "$BIN"
    rm -rf "$LOCK"
    lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null
}
trap restore EXIT
trap 'exit 1' INT TERM HUP

# KUAL closes first and redraws the screen, so let it finish.
sleep 2

# The login token goes outside /mnt/us, which is what a computer sees over USB.
CONFIG_DIR=/var/local/yaknigi
if ! mkdir -p "$CONFIG_DIR" 2>/dev/null; then
    CONFIG_DIR="$DIR/data"
fi

lipc-set-prop com.lab126.pillow disableEnablePillow disable 2>/dev/null
killall -STOP awesome 2>/dev/null
# Keeps /mnt/us mounted if a USB cable gets plugged in while books are being saved.
has_volumd && killall -STOP volumd 2>/dev/null
sleep 1

cp "$DIR/yb-app" "$BIN" && chmod +x "$BIN"

{
    date
    YB_CONFIG="$CONFIG_DIR/config" \
    YB_DATA_DIR="$DIR/data" \
    YB_CA_BUNDLE="$DIR/cacert.pem" \
    YB_UI_FONT="$DIR/DejaVuSans.ttf" \
    YB_BOOK_FONT="$DIR/DejaVuSerif.ttf" \
    "$BIN"
    echo "exit code: $?"
} > "$DIR/app.log" 2>&1
