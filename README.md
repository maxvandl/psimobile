# Psi Mobile

XMPP-клиент для iOS (SwiftUI) с внешним видом Psi+ и PGP по XEP-0027 — совместим с Psi+/Gajim.

## Запуск

```bash
cd ~/git/PsiMobile
./scripts/run.sh                    # симулятор
./scripts/run.sh device ABCDE12345  # iPhone по кабелю; ABCDE12345 = Team ID (Xcode → Settings → Accounts)
```

Скрипт сам поставит xcodegen и go через Homebrew, один раз соберёт GopenPGP, сгенерирует проект и запустит. Лог сборки — `build/run.log`.

Для iPhone: включить Developer Mode (Настройки → Конфиденциальность и безопасность), после установки доверять разработчику (Настройки → Основные → VPN и управление устройством). С бесплатным Apple ID сборка живёт 7 дней.

## Что пока нет
- push XEP-0357 (в фоне сообщения не приходят)
- XEP-0198, Carbons, MAM, управление контактами
- конференции с паролем и закладки

## Лицензия

MIT, см. `LICENSE`. Лицензии зависимостей — в `Resources/Licenses.txt`.
