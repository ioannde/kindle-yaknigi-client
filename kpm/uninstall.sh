#!/bin/sh
rm -f /mnt/us/documents/yaknigi.sh
if [ "$1" != "upgrade" ]; then
    rm -rf /mnt/us/extensions/yaknigi-ko
fi
