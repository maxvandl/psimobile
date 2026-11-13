#!/usr/bin/env bash
# Сборка и запуск Psi Mobile.
#   ./scripts/run.sh              — в симуляторе iPhone
#   ./scripts/run.sh device TEAM  — на подключённом iPhone (TEAM = Team ID из Xcode → Settings → Accounts)
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-sim}"
TEAM="${2:-}"
BUNDLE=am.local.psimobile
LOG=build/run.log
mkdir -p build

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

step "Проверяю инструменты"
xcode-select -p >/dev/null || { echo "Нужен Xcode (App Store), затем: sudo xcode-select -s /Applications/Xcode.app"; exit 1; }
command -v brew >/dev/null || { echo "Нужен Homebrew: https://brew.sh"; exit 1; }
for t in xcodegen go; do command -v $t >/dev/null || brew install $t; done

if [ ! -d Frameworks/Psipgp.xcframework ]; then
  step "Собираю PGP-библиотеку (один раз, ~3–5 мин)"
  ./scripts/build-psipgp.sh
fi

step "Генерирую Xcode-проект"
xcodegen generate --quiet

if [ "$MODE" = "device" ]; then
  if [ -z "$TEAM" ]; then
    TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' | head -1)
    [ -n "$TEAM" ] || { echo "Team ID не найден: Xcode → Settings → Accounts → добавь Apple ID → Manage Certificates → + Apple Development"; exit 1; }
    echo "Team ID: $TEAM"
  fi
  DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && !/simulated/ && !/unavailable/ && /available|connected/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-F-]{25,}$/) {print $i; exit}}')
  [ -n "$DEVICE_ID" ] || { echo "iPhone не найден: подключи кабелем, разблокируй, включи Developer Mode"; exit 1; }
  step "Собираю для iPhone ($DEVICE_ID)"
  xcodebuild -project PsiMobile.xcodeproj -scheme PsiMobile -configuration Debug \
    -destination "id=$DEVICE_ID" -derivedDataPath build/dd \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
    build 2>&1 | tee "$LOG" | grep -E "error:|BUILD" || true
  APP=build/dd/Build/Products/Debug-iphoneos/PsiMobile.app
  grep -q "BUILD SUCCEEDED" "$LOG" || { echo "Сборка не удалась, см. $LOG"; exit 1; }
  step "Устанавливаю и запускаю"
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE" || \
    echo "Если не запустилось: на iPhone Настройки → Основные → VPN и управление устройством → доверять разработчику"
else
  SIM=$(xcrun simctl list devices available | grep -E "iPhone 1[5-9]|iPhone 2" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [ -n "$SIM" ] || { echo "Нет симулятора iPhone: Xcode → Settings → Components"; exit 1; }
  step "Собираю для симулятора"
  xcodebuild -project PsiMobile.xcodeproj -scheme PsiMobile -configuration Debug \
    -destination "id=$SIM" -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tee "$LOG" | grep -E "error:|BUILD" || true
  APP=build/dd/Build/Products/Debug-iphonesimulator/PsiMobile.app
  grep -q "BUILD SUCCEEDED" "$LOG" || { echo "Сборка не удалась, см. $LOG"; exit 1; }
  step "Запускаю симулятор"
  xcrun simctl boot "$SIM" 2>/dev/null || true
  open "$(xcode-select -p)/Applications/Simulator.app"
  xcrun simctl install "$SIM" "$APP"
  xcrun simctl launch "$SIM" "$BUNDLE"
fi
step "Готово"
