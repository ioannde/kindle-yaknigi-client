#!/bin/sh
# What the launcher does with an update, in every state a power cut or a bad version can leave.
SCRIPT=$(CDPATH='' cd "$(dirname "$0")/../../kual/yaknigi-ko" && pwd)/apply-update.sh
BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT
failed=0

setup() {
    DIR=$BASE/$1
    export YAKNIGI_DIR=$DIR KO_HOME=$DIR/home
    UPDATE=$KO_HOME/yaknigi/update
    PLUGIN=$DIR/koreader/plugins/yaknigi.koplugin
    mkdir -p "$PLUGIN/yaknigi" "$UPDATE"
    echo 1.0.0 > "$PLUGIN/yaknigi/VERSION"
}
pending() {
    mkdir -p "$UPDATE/pending/yaknigi.koplugin/yaknigi"
    echo "$1" > "$UPDATE/pending/yaknigi.koplugin/yaknigi/VERSION"
    printf '%s' "$1" > "$UPDATE/pending/ready"
}
apply() { sh "$SCRIPT"; }
have() { cat "$PLUGIN/yaknigi/VERSION" 2>/dev/null; }
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: got '$2', want '$3'"
        failed=1
    fi
}
exists() { [ -e "$1" ] && echo yes || echo no; }

setup nothing
apply
check "nothing waits: nothing changes" "$(have)" 1.0.0

setup install
pending 1.1.0
apply
check "a new version goes in" "$(have)" 1.1.0
check "it is on trial" "$(cat "$UPDATE/trial")" 1.1.0
check "nothing waits after" "$(exists "$UPDATE/pending")" no
check "the old one is kept" "$(cat "$UPDATE/previous.koplugin/yaknigi/VERSION")" 1.0.0

# It started well and said so.
rm "$UPDATE/trial"
apply
check "a confirmed version stays" "$(have)" 1.1.0

setup rollback
pending 1.1.0
apply
apply
check "a start that never confirmed goes back" "$(have)" 1.0.0
check "the version is remembered as bad" "$(cat "$UPDATE/bad")" 1.1.0
check "the trial is over" "$(exists "$UPDATE/trial")" no
apply
check "and it stays back" "$(have)" 1.0.0

setup cut_between_moves
pending 1.1.0
mv "$PLUGIN" "$UPDATE/previous.koplugin"
apply
check "a power cut between the moves: installed after all" "$(have)" 1.1.0
check "with the old one kept" "$(cat "$UPDATE/previous.koplugin/yaknigi/VERSION")" 1.0.0

setup cut_after_trial
pending 1.1.0
mv "$PLUGIN" "$UPDATE/previous.koplugin"
printf 1.1.0 > "$UPDATE/trial"
apply
check "a power cut after the trial was noted: no rollback of nothing" "$(have)" 1.1.0
check "and the version is not called bad" "$(exists "$UPDATE/bad")" no

setup stale
pending 1.0.0
apply
check "not newer: left alone" "$(have)" 1.0.0
check "and dropped" "$(exists "$UPDATE/pending")" no

setup older
pending 0.9.0
apply
check "older: left alone" "$(have)" 1.0.0

setup half_ready
mkdir -p "$UPDATE/pending/yaknigi.koplugin"
apply
check "not marked ready: left alone" "$(have)" 1.0.0

setup no_plugin_dir
mkdir -p "$UPDATE/pending"
printf 1.1.0 > "$UPDATE/pending/ready"
apply
check "marked ready with nothing there: dropped" "$(exists "$UPDATE/pending")" no
check "and the plugin stays" "$(have)" 1.0.0

setup dev_build
rm "$PLUGIN/yaknigi/VERSION"
pending 1.1.0
apply
check "a build without a version takes a release" "$(have)" 1.1.0

setup tens
echo 1.9.0 > "$PLUGIN/yaknigi/VERSION"
pending 1.10.0
apply
check "numbers, not letters" "$(have)" 1.10.0

exit $failed
