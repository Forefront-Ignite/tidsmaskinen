#!/usr/bin/env bash
# Prepends a new <item> to appcast.xml for the just-released version.
#
# Usage:   ./bin/update-appcast.sh <version> <sign_update-output>
# Example: ./bin/update-appcast.sh 0.2.0 'sparkle:edSignature="..." length="12345"'
#
# The second argument is the verbatim stdout of Sparkle's `sign_update` tool
# (a single line: `sparkle:edSignature="..." length="..."`). The enclosure URL
# is derived from the version and points at the GitHub Release asset.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <version> <sign_update-output>" >&2
    exit 1
fi

VERSION="$1"
SIG_LINE="$2"
REPO="Forefront-Ignite/tidsmaskinen"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST="$ROOT/appcast.xml"

if [[ ! -f "$APPCAST" ]]; then
    echo "Error: $APPCAST not found" >&2
    exit 1
fi

PUB_DATE=$(LC_TIME=C TZ=UTC date "+%a, %d %b %Y %H:%M:%S +0000")
ENCLOSURE_URL="https://github.com/$REPO/releases/download/v$VERSION/Tidsmaskinen.zip"

NEW_ITEM=$(cat <<EOF
        <item>
            <title>Version $VERSION</title>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <enclosure url="$ENCLOSURE_URL" $SIG_LINE type="application/octet-stream" />
        </item>
EOF
)

APPCAST_PATH="$APPCAST" NEW_ITEM="$NEW_ITEM" python3 - <<'PY'
import os, re, sys

path = os.environ['APPCAST_PATH']
item = os.environ['NEW_ITEM']

with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Insert just before </channel> so items follow the channel metadata.
# Sparkle picks the highest <sparkle:version> regardless of order.
m = re.search(r'[ \t]*</channel>', content)
if not m:
    sys.exit("appcast.xml: could not locate closing </channel> tag")
content = content[:m.start()] + item.rstrip() + "\n" + content[m.start():]

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
PY

echo "Prepended item for v$VERSION to appcast.xml"
