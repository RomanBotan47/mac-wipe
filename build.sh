#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app="$PWD/build/Протереть Mac.app"
mkdir -p build
staging="$(mktemp -d "$PWD/build/app-stage.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
staged_app="$staging/Протереть Mac.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
for target_arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -parse-as-library -target "${target_arch}-apple-macosx13.0" \
    -file-prefix-map "$PWD"=MacWipe -debug-prefix-map "$PWD"=MacWipe \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework IOKit \
    MacWipe.swift Interface.swift -o "$staging/MacWipe-$target_arch"
done
xcrun lipo -create "$staging/MacWipe-arm64" "$staging/MacWipe-x86_64" -output "$staged_app/Contents/MacOS/MacWipe"
for asset in AutomatoLogo AutomatoFullLogo CleaningHero; do
  cp -X "Assets/$asset.png" "$staged_app/Contents/Resources/$asset.png"
done
cp -X LICENSE "$staged_app/Contents/Resources/LICENSE.txt"
cat > "$staged_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Протереть Mac</string>
<key>CFBundleDisplayName</key><string>Протереть Mac</string>
<key>CFBundleIdentifier</key><string>ru.avtomato.macwipe</string>
<key>CFBundleExecutable</key><string>MacWipe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Автомато · локальная утилита Романа</string>
</dict></plist>
PLIST
mkdir -p "$staging/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" Assets/AutomatoMark.png --out "$staging/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -s format png -z "$double" "$double" Assets/AutomatoMark.png --out "$staging/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$staging/AppIcon.iconset" -o "$staged_app/Contents/Resources/AppIcon.icns"
# Локальная подпись привязана к этой сборке. После пересборки заново добавьте
# установленное приложение в «Универсальный доступ», чтобы macOS обновила привязку.
codesign --force --sign - --identifier ru.avtomato.macwipe "$staged_app"
codesign --verify --deep --strict "$staged_app"
"$staged_app/Contents/MacOS/MacWipe" --self-test
if [[ -L "$app" ]]; then
  print -u2 'Refusing to replace a symbolic-link build target.'
  exit 64
fi
rm -rf -- "$app"
mv "$staged_app" "$app"
printf '%s\n' "$app"
