#!/usr/bin/env bash
# Bundle the self-contained Flutter Linux runner as a standard dpkg package.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.5}"
BUNDLE="${2:-build/linux/x64/release/bundle}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Expected semantic package version, got: $VERSION" >&2
  exit 1
fi
if [[ ! -x "$BUNDLE/ferrypane" ]]; then
  echo "Build the Flutter Linux release before packaging: missing $BUNDLE/ferrypane" >&2
  exit 1
fi
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
PACKAGE="$STAGING/ferrypane"
mkdir -p "$PACKAGE/DEBIAN" "$PACKAGE/opt/ferrypane" "$PACKAGE/usr/share/applications"
cp -a "$BUNDLE/." "$PACKAGE/opt/ferrypane/"
cat > "$PACKAGE/DEBIAN/control" <<EOF
Package: ferrypane
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Maintainer: FerryPane Contributors <noreply@github.com>
Depends: libgtk-3-0 | libgtk-3-0t64, libsecret-1-0 | libsecret-1-0t64, liblzma5 | liblzma5t64, libstdc++6
Description: FerryPane peer-to-peer file manager for local networks
 Browse and copy files between Linux, Windows and Android devices
 over a paired, encrypted connection with no cloud account.
EOF
cat > "$PACKAGE/usr/share/applications/ferrypane.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=FerryPane
Comment=Local peer-to-peer file manager
Exec=/opt/ferrypane/ferrypane
Icon=folder-remote
Terminal=false
Categories=Utility;FileTools;
StartupNotify=true
EOF
chmod 755 "$PACKAGE/opt/ferrypane/ferrypane"
dpkg-deb --root-owner-group --build "$PACKAGE" "FerryPane-linux-amd64.deb"
dpkg-deb --info "FerryPane-linux-amd64.deb"
