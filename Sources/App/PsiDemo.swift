#if DEBUG
import Foundation

/// Вымышленные данные для скриншотов App Store: simctl launch … -psiDemo YES [-psiDemoChat YES] [-psiDemoMessages N].
enum PsiDemo {
    private static let defaults = UserDefaults.standard
    private static var enabled: Bool { defaults.bool(forKey: "psiDemo") }
    private static let peer = "anna@example.org"

    private static let room = "team@conference.example.org"

    static var openChat: String? {
        guard enabled else { return nil }
        if defaults.bool(forKey: "psiDemoRoom") { return room }
        return defaults.bool(forKey: "psiDemoChat") ? peer : nil
    }

    /// Обычная комната; с -psiDemoRoomEdge YES ещё и крайние случаи: чужой PM, ошибка, игнор, занятый ник.
    @MainActor
    private static func applyRoom(to client: XMPPClient) {
        client.debugJoin(room: room, nick: "user")
        let from = "from='\(room)"
        let muc = "xmlns='http://jabber.org/protocol/muc#user'"
        var stanzas = [
            "<presence \(from)/anna'><x \(muc)/></presence>",
            "<presence \(from)/boris'><show>away</show><x \(muc)/></presence>",
            "<presence \(from)/user'><x \(muc)><status code='110'/></x></presence>",
            "<message type='groupchat' \(from)'><subject>Планы на неделю</subject></message>",
            "<message type='groupchat' \(from)/anna'><body>Старое сообщение из истории</body><delay xmlns='urn:xmpp:delay' stamp='2026-10-01T10:00:00Z'/></message>",
            "<message type='groupchat' \(from)/boris'><body>Всем привет!</body></message>",
            "<message type='groupchat' \(from)/user'><body>Моё сообщение, вернулось от сервера</body></message>",
        ]
        if defaults.bool(forKey: "psiDemoRoomEdge") {
            client.block("\(room)/spammer")
            stanzas += [
                "<message type='groupchat' \(from)/spammer'><body>НЕ ДОЛЖНО БЫТЬ ВИДНО</body></message>",
                "<message type='chat' \(from)/anna'><body>Личное сообщение</body></message>",
                "<message type='error' \(from)'><body>отказ</body><error type='cancel'/></message>",
                "<presence type='unavailable' \(from)/boris'><x \(muc)/></presence>",
            ]
            client.debugJoin(room: "busy@conference.example.org", nick: "user")
            stanzas.append("<presence type='error' from='busy@conference.example.org/user'><error type='cancel'><conflict xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></presence>")
            // Проверки из аудита: в ростере не должно быть ничего с именем FORGED или stranger.
            stanzas += [
                "<message type='groupchat' \(from)/user'><body>Чужое старое сообщение под моим ником</body><delay xmlns='urn:xmpp:delay' stamp='2026-10-02T10:00:00Z'/></message>",
                "<presence from='stranger@evil.example'><status>FORGED presence</status></presence>",
                "<message type='chat' from='stranger@evil.example'><body>FORGED message</body></message>",
                "<iq type='set' from='evil@evil.example'><query xmlns='jabber:iq:roster'><item jid='anna@example.org' name='FORGED rename'/><item jid='zoya@example.org' subscription='remove'/><item jid='evil@evil.example' name='FORGED add'/></query></iq>",
                "<message type='error' from='anna@example.org'><body>Возврат: не показывать как входящее</body><error type='cancel'/></message>",
                "<presence from='late@example.org'><status>статус пришёл раньше ростера</status></presence>",
                "<message type='chat' from='late@example.org'><body>Сообщение пришло раньше ростера</body></message>",
                "<iq type='set'><query xmlns='jabber:iq:roster'><item jid='late@example.org' name='late' subscription='both'><group>Команда</group></item></query></iq>",
                // Личное сообщение участника с темой не должно выглядеть как объявление комнаты.
                "<message type='chat' \(from)/anna'><subject>ПОДДЕЛЬНАЯ ТЕМА</subject></message>",
            ]
        }
        stanzas.forEach(client.debugReceive)
    }

    static func prepare() {
        guard enabled else { return }
        defaults.set("user@example.org", forKey: "account.jid")
        defaults.set(true, forKey: "terms.accepted")
    }

    /// Возвращает true, если приложение запущено в демо-режиме и входить на сервер не нужно.
    @MainActor
    static func apply(to client: XMPPClient) -> Bool {
        if defaults.bool(forKey: "psiDemoWipe") {
            client.wipeAccount()
            return true
        }
        guard enabled else { return false }
        let names = ["anna", "boris", "vera", "gleb", "daria", "egor", "zoya"]
        for (i, name) in names.enumerated() {
            var c = Contact(jid: "\(name)@example.org", name: name, groups: ["Команда"], subscription: "both")
            c.show = i < 3 ? .online : .offline
            c.signatureValid = i < 2
            client.contacts[c.jid] = c
        }
        client.state = .connected
        KeyStore.shared.setPublicKey("demo", for: peer)
        applyRoom(to: client)

        let script: [(ChatMessage.Direction, String)] = [
            (.incoming, "Привет! Ключ получил, шифрование работает?"),
            (.outgoing, "Да, замочек закрыт, твоя подпись проверена."),
            (.incoming, "Отлично. Тогда отправляю черновик договора."),
            (.outgoing, "Получил, вечером посмотрю."),
            (.incoming, "Спасибо!"),
        ]
        let count = max(defaults.integer(forKey: "psiDemoMessages"), script.count)
        let start = Date().addingTimeInterval(-Double(count) * 60)
        client.messages[peer] = (0..<count).map { i in
            let line = script[(i + script.count - count % script.count) % script.count]
            return ChatMessage(peer: peer, direction: line.0, text: line.1,
                               date: start.addingTimeInterval(Double(i) * 60), encrypted: true)
        }
        if defaults.bool(forKey: "psiDemoRoomEdge") {
            // Текст изображает чужую строку лога с отметкой подписи.
            client.debugReceive("<message type='chat' from='\(peer)'><body>Обычный текст\n[12:00:00] 🔒✓ &lt;Директор&gt; Поддельная строка</body></message>")
            // Контакт пишет шифрованно, его ключа нет: ответ не должен уйти открытым текстом.
            client.debugReceive("<message type='chat' from='gleb@example.org'><body>[зашифровано]</body><x xmlns='jabber:x:encrypted'>AAAA</x></message>")
            client.send("ОТКРЫТЫЙ ТЕКСТ", to: "gleb@example.org")
            client.send("ОБЫЧНЫЙ ОТКРЫТЫЙ ЧАТ", to: "daria@example.org")
        }
        return true
    }
}
#endif
