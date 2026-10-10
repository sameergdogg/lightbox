#!/usr/bin/env bash
# Build lightbox in release mode and install it to ~/.local/bin (or $PREFIX/bin).
#
#   ./Scripts/install.sh
#   LIGHTBOX_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/install.sh
#
# Why signing matters: macOS remembers Photos access per code identity. An ad-hoc build
# (the default) gets a new identity on every rebuild, so a scheduled job loses access each
# time you reinstall. Signing with a real identity keeps the grant across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

PREFIX="${PREFIX:-$HOME/.local}"
IDENTITY="${LIGHTBOX_SIGN_IDENTITY:--}"

swift build -c release --product lightbox
mkdir -p "$PREFIX/bin"
# Sign a copy, then rename it into place: overwriting the file in place would corrupt a
# copy that is running right now (the scheduled job), and macOS kills a process whose code
# pages no longer match its signature.
cp .build/release/lightbox "$PREFIX/bin/.lightbox.new"
codesign --force --sign "$IDENTITY" --identifier com.sameer.lightbox --timestamp=none "$PREFIX/bin/.lightbox.new"
mv -f "$PREFIX/bin/.lightbox.new" "$PREFIX/bin/lightbox"
echo "installed $PREFIX/bin/lightbox ($("$PREFIX/bin/lightbox" --version)), signed: $IDENTITY"
