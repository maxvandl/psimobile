#!/usr/bin/env bash
# Release-сборка минимального размера и без локальных путей в бинарнике.
#   ./scripts/release-build.sh               — проверочная сборка без подписи
#   ./scripts/release-build.sh archive TEAM  — подписанный архив (TEAM = Team ID платного аккаунта)
#   ./scripts/release-build.sh upload TEAM   — отправить архив в App Store Connect
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ACTION="${1:-build}"
TEAM="${2:-}"
ARCHIVE=build/PsiMobile.xcarchive

if [ "$ACTION" != build ] && [ -z "$TEAM" ]; then
  echo "Нужен Team ID: ./scripts/release-build.sh $ACTION TEAM"
  exit 1
fi

if [ "$ACTION" = upload ]; then
  [ -d "$ARCHIVE" ] || { echo "Сначала: ./scripts/release-build.sh archive $TEAM"; exit 1; }
  OPTIONS="$(mktemp)"
  trap 'rm -f "$OPTIONS"' EXIT
  cat > "$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
    -exportPath build/export -allowProvisioningUpdates
  exit 0
fi

xcodegen generate --quiet

ARGS=(-project PsiMobile.xcodeproj -scheme PsiMobile -configuration Release
  -destination generic/platform=iOS -derivedDataPath build/rel)
if [ "$ACTION" = archive ]; then
  # Номер сборки должен быть новым при каждой загрузке.
  ARGS+=(-archivePath "$ARCHIVE" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic
    CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" archive)
else
  ARGS+=(CODE_SIGNING_ALLOWED=NO build)
fi

# Настройки в командной строке применяются и к SwiftPM-пакетам, поэтому они здесь, а не в project.yml.
xcodebuild "${ARGS[@]}" \
  GCC_OPTIMIZATION_LEVEL=z \
  SWIFT_OPTIMIZATION_LEVEL=-Osize \
  SWIFT_COMPILATION_MODE=wholemodule \
  DEAD_CODE_STRIPPING=YES \
  ASSETCATALOG_COMPILER_OPTIMIZATION=space \
  LD_GENERATE_MAP_FILE=YES \
  OTHER_CFLAGS="-ffile-prefix-map=$ROOT=." \
  OTHER_SWIFT_FLAGS="-file-prefix-map $ROOT=." \
  > build/release.log 2>&1 || { grep -E " error:" build/release.log | sort -u; echo "Сборка не удалась, см. build/release.log"; exit 1; }

if [ "$ACTION" = archive ]; then
  APP="$ARCHIVE/Products/Applications/PsiMobile.app"
else
  APP=build/rel/Build/Products/Release-iphoneos/PsiMobile.app
fi
echo "Размер: $(du -sh "$APP" | cut -f1), локальных путей: $(strings "$APP/PsiMobile" | grep -c "^$ROOT" || true)"
