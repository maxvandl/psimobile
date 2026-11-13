#!/usr/bin/env bash
# Собирает Go/psipgp (обёртка над GopenPGP от ProtonMail) в Frameworks/Psipgp.xcframework для iOS.
# Нужны: Xcode, Go 1.21+.  brew install go
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Вне домашней папки: путь сборки остаётся в бинарнике.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PATH="$PATH:$(go env GOPATH)/bin"

# Версии закреплены: обновлять осознанно, сверив изменения.
MOBILE=v0.0.0-20261011034528-197770444867
GOPENPGP_TAG=v2.11.1-proton
GOPENPGP_COMMIT=0533d1ff497e6ac35e37fca35eb26957f107901d

go install "golang.org/x/mobile/cmd/gomobile@$MOBILE"
go install "golang.org/x/mobile/cmd/gobind@$MOBILE"
gomobile init

git clone https://github.com/ProtonMail/gopenpgp.git "$WORK"
cd "$WORK"
git checkout "$GOPENPGP_TAG"
[ "$(git rev-parse HEAD)" = "$GOPENPGP_COMMIT" ] || { echo "Тег $GOPENPGP_TAG указывает не на ожидаемый коммит"; exit 1; }
go get "golang.org/x/mobile/bind@$MOBILE"
cp -R "$ROOT/Go/psipgp" ./psipgp

# Совместимость с настоящим gpg на одноразовых ключах: без неё библиотеку собирать нельзя.
go test -count=1 ./psipgp/

rm -rf "$ROOT/Frameworks/Psipgp.xcframework"
mkdir -p "$ROOT/Frameworks"
gomobile bind -target=ios/arm64,iossimulator/arm64 -iosversion=17.0 \
  -trimpath -ldflags="-s -w" \
  -o "$ROOT/Frameworks/Psipgp.xcframework" \
  ./psipgp

echo "OK: $ROOT/Frameworks/Psipgp.xcframework"
