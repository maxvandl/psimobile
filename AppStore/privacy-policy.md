# Политика конфиденциальности Psi Mobile

Дата вступления в силу: [ДАТА]. Контакт: [EMAIL РАЗРАБОТЧИКА].

Psi Mobile — клиент протокола XMPP. Приложение подключается к серверу, который указываете вы. У разработчика нет собственного сервера для сообщений, и он не получает ваши данные.

## Что хранится на устройстве
- Адрес аккаунта (JID), хост и порт, настройки приложения.
- Пароль аккаунта и ключи OpenPGP: в Keychain, только на этом устройстве.
- История сообщений: в файлах приложения, в расшифрованном виде. Файлы не попадают в резервные копии iCloud и iTunes. Они удаляются вместе с приложением.

## Что передаётся
- **Вашему XMPP-серверу:** адрес аккаунта, пароль при входе, статус, список контактов, сообщения, блокировки и жалобы. Обрабатывает эти данные администратор сервера по своим правилам. Сообщения без шифрования OpenPGP видны серверу.
- **Контактам:** ваши сообщения, статус и подпись OpenPGP.
- **Push-сервису, если вы его указали:** токен устройства Apple. Сервис передаёт его Apple для доставки уведомлений.

## Чего приложение не делает
Нет рекламы, аналитики, отслеживания и передачи данных третьим лицам со стороны разработчика.

## Жалобы и блокировка
Пользователя можно заблокировать и пожаловаться на него в меню чата. Жалоба уходит администратору вашего сервера. Запрещены оскорбления, угрозы, спам и незаконные материалы.

## Удаление данных
В настройках аккаунта есть кнопка «Удалить аккаунт с устройства»: она стирает пароль, ключи, историю и настройки. Удаление приложения стирает историю и настройки, а пароль и ключи будут стёрты при следующей установке. Данные на сервере удаляются через его администратора.

---

# Psi Mobile Privacy Policy

Effective date: [DATE]. Contact: [DEVELOPER EMAIL].

Psi Mobile is an XMPP client. It connects to the server you specify. The developer runs no message server and does not receive your data.

## Stored on your device
- Account address (JID), host and port, app settings.
- Account password and OpenPGP keys: in the Keychain, on this device only.
- Message history: in app files, decrypted. The files are excluded from iCloud and iTunes backups and are removed with the app.

## What is transmitted
- **To your XMPP server:** account address, password at login, status, contact list, messages, blocks and reports. The server administrator handles this data under their own rules. Messages sent without OpenPGP encryption are visible to the server.
- **To your contacts:** your messages, status and OpenPGP signature.
- **To a push service, if you set one:** your Apple device token, which the service passes to Apple to deliver notifications.

## What the app does not do
No ads, analytics, tracking, or sharing of data with third parties by the developer.

## Reports and blocking
You can block and report a user from the chat menu. Reports go to your server's administrator. Abuse, threats, spam and illegal content are prohibited.

## Deleting data
Delete the app to erase history and settings on the device. Data on the server is removed through its administrator.
