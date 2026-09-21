#!/usr/bin/env bash
# Runs a throwaway dev instance of Tidsmaskinen *beside* the installed app:
# ad-hoc signed, bundle id se.forefront.tidsmaskinen.dev, on a snapshot of the
# real database in its own data dir (TIDSMASKINEN_DATA_DIR), so it never
# touches the live DB, the hook events log, the installed app's TCC grants or
# its keychain items. Used to screenshot/judge a branch while the real app
# keeps recording. Stop it with: pkill -f 'Tidsmaskinen Dev.app'
#
# Usage: bin/dev-instance.sh [debug|release]
set -euo pipefail
CONFIG="${1:-debug}"
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DEV_APP="$ROOT/build/Tidsmaskinen Dev.app"
DATA_DIR="$ROOT/build/dev-data"
REAL_DB="$HOME/Library/Application Support/Tidsmaskinen/db.sqlite"

SIGNING_IDENTITY=- ./bin/make-app.sh "$CONFIG"

# Stop a previous copy and wait for it to close its database before the
# bundle and the snapshot are replaced underneath it.
if pkill -f "Tidsmaskinen Dev.app" 2>/dev/null; then
    for _ in $(seq 1 50); do
        pgrep -f "Tidsmaskinen Dev.app" >/dev/null 2>&1 || break
        sleep 0.1
    done
    pkill -9 -f "Tidsmaskinen Dev.app" 2>/dev/null || true
fi
mkdir -p "$ROOT/build"
rm -rf "$DEV_APP"
cp -R "$ROOT/Tidsmaskinen.app" "$DEV_APP"
PLIST="$DEV_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier se.forefront.tidsmaskinen.dev" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Tidsmaskinen Dev" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Tidsmaskinen Dev" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Tidsmaskinen Dev" "$PLIST"
# Re-seal after the plist edit. No hardened runtime, so library validation
# can't refuse the ad-hoc-signed Sparkle framework.
codesign --force --deep --sign - "$DEV_APP" 2>&1 | sed 's/^/    /'

mkdir -p "$DATA_DIR"
rm -f "$DATA_DIR/db.sqlite" "$DATA_DIR/db.sqlite-wal" "$DATA_DIR/db.sqlite-shm"
if [[ -f "$REAL_DB" ]]; then
    # .backup gives a consistent snapshot even while the live app is writing (WAL).
    sqlite3 "$REAL_DB" ".backup '$DATA_DIR/db.sqlite'"
    echo "==> Snapshotted the live database to $DATA_DIR/db.sqlite"
fi

# Never let the dev copy check for (and install) a release over itself, and
# skip Sparkle's first-launch "check automatically?" prompt.
defaults write se.forefront.tidsmaskinen.dev SUEnableAutomaticChecks -bool false
defaults write se.forefront.tidsmaskinen.dev SUHasLaunchedBefore -bool true

TIDSMASKINEN_DATA_DIR="$DATA_DIR" nohup "$DEV_APP/Contents/MacOS/Tidsmaskinen" \
    >"$ROOT/build/dev-instance.log" 2>&1 &
echo "==> Dev instance running (pid $!) — data dir $DATA_DIR, log build/dev-instance.log"
