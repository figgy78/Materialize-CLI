#!/bin/bash
# Build Materialize.app - a self-contained macOS app bundle around the CLI.
#
#   ./macos/build-app.sh              build into ./dist
#   ./macos/build-app.sh --install    build, then copy into /Applications
#
# Needs only the Xcode Command Line Tools (swiftc, sips, iconutil, codesign)
# and cargo. The resulting bundle carries its own CLI binary, web UI and
# Python server, so it keeps working if this checkout moves or is deleted.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
APP="$DIST/Materialize.app"
CONTENTS="$APP/Contents"
BUILD="$DIST/.build"
VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' Cargo.toml | head -1)"

say() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v swiftc >/dev/null || die "swiftc not found. Run: xcode-select --install"

# --- 1. the CLI binary -------------------------------------------------------
if ! command -v cargo >/dev/null; then
    # rustup's default install is not on a Finder-launched PATH either.
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
fi
command -v cargo >/dev/null || die "cargo not found. Install Rust from https://rustup.rs"

say "Building the CLI (release)"
cargo build --release --quiet
CLI="$ROOT/target/release/materialize-cli"
[ -x "$CLI" ] || die "expected $CLI after cargo build"

# --- 2. the icon -------------------------------------------------------------
say "Rendering the app icon"
rm -rf "$BUILD"
mkdir -p "$BUILD/AppIcon.iconset"
python3 "$ROOT/macos/make-icon.py" "$BUILD/icon-1024.png" 1024 >/dev/null
for size in 16 32 64 128 256 512; do
    sips -z $size $size "$BUILD/icon-1024.png" \
        --out "$BUILD/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
done
# @2x variants are the next size up under a different name.
cp "$BUILD/AppIcon.iconset/icon_32x32.png"   "$BUILD/AppIcon.iconset/icon_16x16@2x.png"
cp "$BUILD/AppIcon.iconset/icon_64x64.png"   "$BUILD/AppIcon.iconset/icon_32x32@2x.png"
cp "$BUILD/AppIcon.iconset/icon_256x256.png" "$BUILD/AppIcon.iconset/icon_128x128@2x.png"
cp "$BUILD/AppIcon.iconset/icon_512x512.png" "$BUILD/AppIcon.iconset/icon_256x256@2x.png"
cp "$BUILD/icon-1024.png"                    "$BUILD/AppIcon.iconset/icon_512x512@2x.png"
rm "$BUILD/AppIcon.iconset/icon_64x64.png"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"

# --- 3. the app binary -------------------------------------------------------
say "Compiling Materialize.app"
swiftc -O -target arm64-apple-macos12.0 \
    -framework AppKit -framework WebKit \
    -o "$BUILD/Materialize" "$ROOT/macos/main.swift"

# --- 4. assemble the bundle --------------------------------------------------
say "Assembling the bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/ui" "$CONTENTS/Resources/bin"

mv "$BUILD/Materialize" "$CONTENTS/MacOS/Materialize"
cp "$BUILD/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT/ui/serve.py" "$ROOT/ui/index.html" "$CONTENTS/Resources/ui/"
cp "$CLI" "$CONTENTS/Resources/bin/materialize"
chmod +x "$CONTENTS/Resources/bin/materialize" "$CONTENTS/MacOS/Materialize"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>Materialize</string>
    <key>CFBundleDisplayName</key>         <string>Materialize</string>
    <key>CFBundleExecutable</key>          <string>Materialize</string>
    <key>CFBundleIdentifier</key>          <string>io.github.figgy78.materialize</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>      <string>12.0</string>
    <key>LSApplicationCategoryType</key>   <string>public.app-category.graphics-design</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSHumanReadableCopyright</key>    <string>MIT. Based on Materialize by Bounding Box Software.</string>
    <!-- The UI is served from 127.0.0.1 over plain HTTP; this key permits
         local connections only and changes nothing for public hosts. -->
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# --- 5. sign -----------------------------------------------------------------
# Apple silicon refuses to run unsigned arm64 code; an ad-hoc signature is
# enough for a locally built app. Inner binaries first, then the bundle.
say "Signing (ad-hoc)"
codesign --force --sign - "$CONTENTS/Resources/bin/materialize" 2>/dev/null
codesign --force --sign - "$CONTENTS/MacOS/Materialize" 2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null
codesign --verify --deep "$APP" || die "signature verification failed"

rm -rf "$BUILD"

if [ "${1:-}" = "--install" ]; then
    say "Installing to /Applications"
    rm -rf "/Applications/Materialize.app"
    cp -R "$APP" "/Applications/Materialize.app"
    APP="/Applications/Materialize.app"
fi

SIZE="$(du -sh "$APP" | cut -f1)"
printf '\n\033[1;32m✓\033[0m %s  (%s)\n' "$APP" "$SIZE"
printf '  open it with:  open "%s"\n' "$APP"
