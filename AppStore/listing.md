# Карточка App Store

**Название:** Psi Mobile (проверить, свободно ли, при создании приложения)
**Подзаголовок:** XMPP-чат с шифрованием PGP
**Категория:** Социальные сети
**Ключевые слова:** xmpp,jabber,pgp,openpgp,чат,шифрование,psi,мессенджер

## Описание
Psi Mobile — клиент XMPP (Jabber) для iPhone в стиле настольного Psi+.

- Подключение к любому XMPP-серверу с обязательным TLS
- Шифрование сообщений OpenPGP по XEP-0027, совместимо с Psi+ и Gajim
- Подпись статуса и проверка подписи контактов
- Контакты по группам, как в Psi+
- Конференции (без шифрования)
- История переписки на устройстве
- Блокировка контактов и жалобы

Нужен аккаунт на XMPP-сервере. Приложение не предоставляет сервер. Пока приложение закрыто, сообщения приходят, только если на сервере и в настройках настроен push.

## Заметки для App Review
```
Psi Mobile is a client for the open XMPP protocol. It needs an account on an XMPP server.

Test account: [JID]
Password: [PASSWORD]
Second account to chat with: [JID]

Steps: accept the terms, tap the wrench icon, enter the JID and password, tap Connect.
Block and report: open a chat, tap the lock icon in the top right corner.
OpenPGP: encryption needs a key, which is optional for testing basic chat.
Contact for reports: [EMAIL]
```

## Приватность в App Store Connect
Сбор данных разработчиком: **нет** (Data Not Collected). Перепроверить, если появится свой push-сервис: через него пойдут токены устройств.

## Скриншоты
Папка `screenshots/`. Контакты и сообщения в них вымышленные. Пересъёмка: Debug-сборка на симуляторе с аргументами `-psiDemo YES`, `-psiDemoChat YES`.

## Что заполнить перед отправкой
- [ ] `AppInfo.supportURL` в `Sources/UI/AccountView.swift`
- [ ] Bundle ID в `project.yml`
- [ ] Email и дата в `privacy-policy.md`, опубликовать её по публичной ссылке
- [ ] Тестовые аккаунты на сервере с действующим сертификатом
- [ ] Export compliance: см. `export-compliance.md`
- [ ] Лицензии: показать в приложении или описании уведомления зависимостей (GopenPGP — MIT, остальные — BSD, Apache и public domain; кода LGPL больше нет)
