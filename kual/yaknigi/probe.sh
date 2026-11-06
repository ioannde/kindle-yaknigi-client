#!/bin/sh
# Device check. Writes probe.log next to this script and then returns to the
# Kindle home screen. Runs from /tmp, because /mnt/us may not allow execution.
DIR=/mnt/us/extensions/yaknigi
LOG="$DIR/probe.log"

# KUAL closes first and redraws the screen, so let it finish.
sleep 2

{
    date
    uname -a
    cat /etc/prettyversion.txt 2>/dev/null
    cp "$DIR/yb-probe" /tmp/yb-probe && chmod +x /tmp/yb-probe
    YB_CA_BUNDLE="$DIR/cacert.pem" YB_FONT="$DIR/DejaVuSans.ttf" /tmp/yb-probe
    echo "exit code: $?"
    rm -f /tmp/yb-probe
} > "$LOG" 2>&1

lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home
