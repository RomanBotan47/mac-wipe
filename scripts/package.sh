#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app="$PWD/build/Протереть Mac.app"
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
if [[ -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_NAME}" == v* && "${GITHUB_REF_NAME}" != "v$version" ]]; then
  print -u2 'Release tag does not match the application version.'
  exit 65
fi
mkdir -p build/release
stage="$(mktemp -d "$PWD/build/distribution.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
ditto --noextattr --noqtn --norsrc "$app" "$stage/Протереть Mac.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/Прочитай меня.txt" <<'TEXT'
Протереть Mac · Автомато

Перетащи «Протереть Mac.app» в папку «Программы» и запусти его оттуда.
Включи приложение в «Конфиденциальность и безопасность → Универсальный доступ».

Это открытая сборка с локальной ad-hoc подписью, без Developer ID и нотариализации Apple.
Сведения о первом запуске, проверке SHA-256 и исходники:
https://github.com/RomanBotan47/mac-wipe
Официальная инструкция Apple: https://support.apple.com/ru-ru/102445

Для выхода из протирки удерживай мышь на жёлтой кнопке и отпусти.
Аварийный выход: Command + Option + Esc. Автовыход включён всегда.
При протирке обходи кнопку питания / Touch ID.

Разработано в AI-студии «Автомато»: https://автомато.рф
TEXT
hdiutil create -quiet -volname "Протереть Mac $version" -srcfolder "$stage" -format UDZO -ov "$PWD/build/release/MacWipe-$version-universal.dmg"
python3 - "$app" "$PWD/build/release/MacWipe-$version-universal.zip" <<'PY'
from pathlib import Path
import sys
import zipfile
source, output = map(Path, sys.argv[1:])
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(source.rglob('*')):
        if path.is_file():
            archive.write(path, path.relative_to(source.parent))
PY
cd build/release
shasum -a 256 "MacWipe-$version-universal.dmg" "MacWipe-$version-universal.zip" > SHA256SUMS.txt
printf '%s\n' "Created universal DMG, ZIP, and SHA256SUMS.txt"
