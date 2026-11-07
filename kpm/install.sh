#!/bin/sh
# The program lives outside the package, as KOReader's own does: KPM replaces a package's
# files on upgrade, and home/ in there holds the sign-in and the books.
DEST=/mnt/us/extensions/yaknigi-ko
mkdir -p "$DEST"
rm -rf "$DEST/koreader"
cp -rf ./yaknigi-ko/. "$DEST/"
rm -rf ./yaknigi-ko
cp -f scriptlets/yaknigi.sh /mnt/us/documents/yaknigi.sh
