import CocoaAsyncSocket
import CryptoKit
import Foundation
import UIKit
import UserNotifications
import XMPPFramework

extension Notification.Name {
    static let psiPushToken = Notification.Name("psiPushToken")
}

/// Причина жалобы (XEP-0377).
enum ReportReason: String, CaseIterable, Identifiable {
    case spam, abuse
    var id: String { rawValue }
    var title: String { self == .spam ? "Спам" : "Оскорбления" }
    var urn: String { "urn:xmpp:reporting:\(rawValue)" }
}

/// Обёртка над XMPPFramework: соединение, ростер, presence, сообщения с PGP (XEP-0027).
@MainActor
final class XMPPClient: NSObject, ObservableObject {
    enum ConnectionState: Equatable { case disconnected, connecting, connected, error(String) }

    @Published var state: ConnectionState = .disconnected
    @Published var contacts: [String: Contact] = [:]
    @Published var messages: [String: [ChatMessage]] = [:]
    /// Свой статус всегда «В сети»; реальное состояние соединения — в `state`.
    @Published private(set) var myShow: PresenceShow = .online
    @Published var myStatus: String = ""
    /// JID, для которых шифрование выключено вручную. Если ключ контакта есть, по умолчанию оно включено.
    @Published var pgpDisabled = Set(UserDefaults.standard.stringArray(forKey: "pgp.disabledChats") ?? []) {
        didSet { UserDefaults.standard.set(Array(pgpDisabled), forKey: "pgp.disabledChats") }
    }
    /// Контакты, с которыми переписка уже шла шифрованно: без их ключа сообщение не уйдёт открытым.
    @Published private var pgpExpected = Set(UserDefaults.standard.stringArray(forKey: "pgp.expectedChats") ?? []) {
        didSet { UserDefaults.standard.set(Array(pgpExpected), forKey: "pgp.expectedChats") }
    }
    /// Соединение держится на закреплённом сертификате: обычная проверка TLS не прошла.
    @Published private(set) var tlsPinned = false

    private let stream = XMPPStream()
    private let reconnect = XMPPReconnect()
    private let rosterStorage = XMPPRosterMemoryStorage()!
    private lazy var roster = XMPPRoster(rosterStorage: rosterStorage)
    @Published private(set) var blocked = Set(UserDefaults.standard.stringArray(forKey: "blocked.jids") ?? []) {
        didSet { UserDefaults.standard.set(Array(blocked), forKey: "blocked.jids") }
    }
    @Published private(set) var conferences: [String: Conference] = {
        let saved = UserDefaults.standard.dictionary(forKey: "conferences") as? [String: String] ?? [:]
        return saved.reduce(into: [:]) { $0[$1.key] = Conference(jid: $1.key, nick: $1.value) }
    }()
    /// Возможности сервера и аккаунта (XEP-0030).
    @Published private(set) var serverFeatures: Set<String> = []

    private var password = ""
    /// Соединение нельзя открыть, пока закрывается прежнее.
    private var connectAfterDisconnect: (() -> Void)?
    /// Почему закрыли соединение сами: иначе в состоянии останется просто «нет соединения».
    private var disconnectReason: String?
    /// Запросы disco: id и у кого спрашивали.
    private var discoRequests: [String: String] = [:]
    /// Номер последнего presence контакта: результат проверки старой подписи не должен применяться к новому.
    private var presenceSerial: [String: Int] = [:]
    private var rosterLoaded = false
    private var loadedHistory: Set<String> = []
    /// Что пришло от JID не из ростера, пока он не загружен: применяется, если контакт появится, остальное отбрасывается.
    private var pendingPresence: [String: XMPPPresence] = [:]
    private var pendingMessages: [XMPPMessage] = []
    private static let pendingLimit = 200
    private let pgp = PGPService.shared

    private enum NS {
        static let encrypted = "jabber:x:encrypted"
        static let signed = "jabber:x:signed"
        static let blocking = "urn:xmpp:blocking"
        static let reporting = "urn:xmpp:reporting:1"
        static let push = "urn:xmpp:push:0"
        static let discoInfo = "http://jabber.org/protocol/disco#info"
        static let muc = "http://jabber.org/protocol/muc"
        static let mucUser = "http://jabber.org/protocol/muc#user"
    }

    override init() {
        super.init()
        reconnect.activate(stream)
        roster.autoFetchRoster = true
        // Подписку на статус подтверждает человек, а не библиотека, даже если контакт уже в ростере.
        roster.autoAcceptKnownPresenceSubscriptionRequests = false
        roster.activate(stream)
        stream.addDelegate(self, delegateQueue: .main)
        roster.addDelegate(self, delegateQueue: .main)
        NotificationCenter.default.addObserver(forName: .psiPushToken, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendPushEnable() }
        }
    }

    var myJID: String? { stream.myJID?.bare }
    var isDisconnected: Bool { stream.isDisconnected }

    // MARK: Соединение

    func connect(jid: String, password: String, host: String?, port: UInt16?) {
        guard stream.isDisconnected else {
            connectAfterDisconnect = { [weak self] in self?.connect(jid: jid, password: password, host: host, port: port) }
            return
        }
        guard let j = XMPPJID(string: jid) else { state = .error("Неверный JID"); return }
        self.password = password
        stream.myJID = j.withNewResource("PsiMobile")
        // Хост прежнего аккаунта не должен оставаться: пароль уйдёт не на тот сервер.
        stream.hostName = host?.isEmpty == false ? host : nil
        stream.hostPort = port ?? 5222
        stream.startTLSPolicy = .required
        state = .connecting
        do {
            try stream.connect(withTimeout: 30)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func disconnect() {
        sendPresence(.offline)
        stream.disconnectAfterSending()
    }

    /// Удаляет с устройства всё, что относится к аккаунту. На сервере аккаунт остаётся.
    func wipeAccount() {
        connectAfterDisconnect = nil
        if !stream.isDisconnected { disconnect() }
        stream.myJID = nil
        password = ""
        KeyStore.deleteAll()
        pgp.resetCache()
        HistoryStore.shared.deleteAll()
        for key in ["account.jid", "account.host", "account.port", "account.pushService",
                    "account.certPin", "account.certPinDomain", "push.token"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        contacts = [:]
        messages = [:]
        loadedHistory = []
        pgpDisabled = []
        pgpExpected = []
        blocked = []
        conferences = [:]
        saveConferences()
        serverFeatures = []
        pendingPresence = [:]
        pendingMessages = []
        myStatus = ""
        tlsPinned = false
    }

    // MARK: Presence

    func setStatus(text: String) {
        myStatus = text
        if stream.isConnected { sendPresence(.online) }
    }

    private func sendPresence(_ show: PresenceShow) {
        let presence = show == .offline ? XMPPPresence(type: "unavailable") : XMPPPresence()
        if let s = show.xmppShow { presence.addChild(DDXMLElement(name: "show", stringValue: s)) }
        if !myStatus.isEmpty { presence.addChild(DDXMLElement(name: "status", stringValue: myStatus)) }
        presence.addChild(DDXMLElement(name: "priority", stringValue: "5"))
        // XEP-0027: подписываем статус, если есть свой ключ.
        if show != .offline, let sig = try? pgp.signPresence(status: myStatus) {
            let x = DDXMLElement(name: "x", xmlns: NS.signed)
            x.stringValue = sig
            presence.addChild(x)
        }
        stream.send(presence)
    }

    // MARK: Сообщения

    func send(_ text: String, to jid: String) {
        guard let to = XMPPJID(string: jid) else { return }
        let message = XMPPMessage(type: "chat", to: to)
        message.addAttribute(withName: "id", stringValue: UUID().uuidString)
        var encrypted = false

        if isEncrypted(jid) {
            do {
                let payload = try pgp.encrypt(text, to: jid)
                message.addBody("[Сообщение зашифровано (XEP-0027)]")
                let x = DDXMLElement(name: "x", xmlns: NS.encrypted)
                x.stringValue = payload
                message.addChild(x)
                // XEP-0380: подсказываем другим клиентам, чем зашифровано.
                let eme = DDXMLElement(name: "encryption", xmlns: "urn:xmpp:eme:0")
                eme.addAttribute(withName: "namespace", stringValue: NS.encrypted)
                message.addChild(eme)
                // Сохранять в архиве сервера (XEP-0334).
                message.addChild(DDXMLElement(name: "store", xmlns: "urn:xmpp:hints"))
                encrypted = true
                pgpExpected.insert(jid)
            } catch {
                append(ChatMessage(peer: jid, direction: .system,
                                   text: "Не отправлено: \(error.localizedDescription)",
                                   date: Date(), encrypted: false))
                return
            }
        } else {
            message.addBody(text)
        }

        message.addChild(DDXMLElement(name: "active", xmlns: "http://jabber.org/protocol/chatstates"))
        stream.send(message)
        append(ChatMessage(peer: jid, direction: .outgoing, text: text, date: Date(), encrypted: encrypted))
    }

    /// Если шифрование ожидается, а ключа нет или он не прочитался, `send` откажет, а не отправит открытым текстом.
    func isEncrypted(_ jid: String) -> Bool {
        guard !pgpDisabled.contains(jid) else { return false }
        return KeyStore.shared.mayHavePublicKey(for: jid) || pgpExpected.contains(jid)
    }

    func togglePGP(for jid: String) {
        if pgpDisabled.contains(jid) { pgpDisabled.remove(jid) } else { pgpDisabled.insert(jid) }
    }

    /// История подгружается при первом обращении к чату: у контакта могут быть тысячи сообщений.
    func loadHistory(_ peer: String) {
        // Файлы закрыты, пока телефон заблокирован: загрузим при следующем обращении.
        guard UIApplication.shared.isProtectedDataAvailable, loadedHistory.insert(peer).inserted else { return }
        let existing = messages[peer] ?? []
        let ids = Set(existing.map(\.id))
        messages[peer] = HistoryStore.shared.load(peer).filter { !ids.contains($0.id) } + existing
    }

    private func append(_ msg: ChatMessage) {
        loadHistory(msg.peer)
        messages[msg.peer, default: []].append(msg)
        if msg.direction != .system { HistoryStore.shared.append(msg) }
    }

    // MARK: Конференции (XEP-0045)

    func join(room: String, nick: String) {
        let jid = room.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard XMPPJID(string: jid)?.user != nil, !nick.isEmpty else { return }
        conferences[jid] = Conference(jid: jid, nick: nick)
        saveConferences()
        enter(jid)
    }

    func leave(room: String) {
        if let c = conferences[room], stream.isConnected, let to = XMPPJID(string: "\(room)/\(c.nick)") {
            stream.send(XMPPPresence(type: "unavailable", to: to))
        }
        conferences[room] = nil
        saveConferences()
    }

    /// В конференцию сообщение не дублируется локально: сервер вернёт его всем участникам, и автору тоже.
    func sendToRoom(_ text: String, room: String) {
        guard let to = XMPPJID(string: room) else { return }
        let message = XMPPMessage(type: "groupchat", to: to)
        message.addAttribute(withName: "id", stringValue: UUID().uuidString)
        message.addBody(text)
        stream.send(message)
    }

    private func saveConferences() {
        UserDefaults.standard.set(conferences.mapValues(\.nick), forKey: "conferences")
    }

    private func enter(_ room: String) {
        guard stream.isConnected, let c = conferences[room], let to = XMPPJID(string: "\(room)/\(c.nick)") else { return }
        loadHistory(room)
        let history = DDXMLElement(name: "history")
        // Только то, чего ещё нет в сохранённой истории.
        if let last = messages[room]?.last?.date {
            let since = ISO8601DateFormatter().string(from: last.addingTimeInterval(1))
            history.addAttribute(withName: "since", stringValue: since)
        } else {
            history.addAttribute(withName: "maxstanzas", stringValue: "50")
        }
        let x = DDXMLElement(name: "x", xmlns: NS.muc)
        x.addChild(history)
        let presence = XMPPPresence(type: nil, to: to)
        presence.addChild(x)
        stream.send(presence)
    }

    private func handleRoomPresence(_ presence: XMPPPresence, room: String) {
        guard var c = conferences[room], let nick = presence.from?.resource else { return }
        let x = presence.child("x", ns: NS.mucUser)
        let codes = (x?.elements(forName: "status") ?? []).compactMap { $0.attributeStringValue(forName: "code") }
        // Настоящий JID виден только в неанонимных комнатах; по нему игнор не обойти сменой ника.
        let realJID = x?.elements(forName: "item").first?.attributeStringValue(forName: "jid")
            .flatMap { XMPPJID(string: $0)?.bare }
        let isSelf = codes.contains("110")
        switch presence.type {
        case "error":
            c.joined = false
            c.error = Self.joinError(presence)
        case "unavailable":
            c.occupants[nick] = nil
            c.occupantJIDs[nick] = nil
            if isSelf { c.joined = false }
        default:
            c.occupants[nick] = PresenceShow(xmppShow: presence.show, available: true)
            c.occupantJIDs[nick] = realJID
            if isSelf {
                c.joined = true
                c.error = nil
                c.nick = nick
            }
        }
        conferences[room] = c
    }

    private static func joinError(_ presence: XMPPPresence) -> String {
        let reasons = presence.elements(forName: "error").first?.children?.compactMap(\.name) ?? []
        if reasons.contains("conflict") { return "Этот ник уже занят" }
        if reasons.contains("not-authorized") { return "Нужен пароль комнаты" }
        if reasons.contains("registration-required") { return "Вход только для участников" }
        if reasons.contains("forbidden") { return "Вход запрещён" }
        return "Не удалось войти"
    }

    /// Время в <delay> задаёт отправитель. Будущее не принимаем: оно сбило бы запрос истории комнаты при входе.
    private static func date(of message: XMPPMessage) -> Date {
        min(message.delayedDeliveryDate ?? Date(), Date())
    }

    /// В личном чате задержку ставит только свой сервер (офлайн-доставка): контакт мог бы вписать время задним числом
    /// и подложить сообщение в старую часть истории.
    private func directDate(of message: XMPPMessage) -> Date {
        guard let delayFrom = message.delayedDeliveryFrom, let own = stream.myJID?.domain,
              delayFrom.user == nil, delayFrom.domain == own else { return Date() }
        return Self.date(of: message)
    }

    private func handleRoomMessage(_ message: XMPPMessage, room: String) {
        guard let c = conferences[room] else { return }
        let nick = message.from?.resource
        if let nick {
            if blocked.contains("\(room)/\(nick)") { return }
            if let real = c.occupantJIDs[nick], blocked.contains(real) { return }
        }
        let date = Self.date(of: message)

        if message.type == "error" {
            append(ChatMessage(peer: room, direction: .system, text: "Сообщение не доставлено",
                               date: date, encrypted: false))
            return
        }
        guard let body = message.body, !body.isEmpty else {
            // В личном сообщении участника тема выглядела бы как объявление комнаты.
            if message.type == "groupchat",
               let subject = message.elements(forName: "subject").first?.stringValue, !subject.isEmpty {
                append(ChatMessage(peer: room, direction: .system, text: "Тема: \(subject)", date: date, encrypted: false))
            }
            return
        }
        guard let nick else {
            append(ChatMessage(peer: room, direction: .system, text: body, date: date, encrypted: false))
            return
        }
        if message.type == "groupchat" {
            // Ник уникален только сейчас: в истории под ним мог писать другой человек.
            let isMine = nick == c.nick && message.delayedDeliveryDate == nil
            append(ChatMessage(peer: room, direction: isMine ? .outgoing : .incoming, text: body,
                               date: date, encrypted: false, nick: nick))
        } else {
            append(ChatMessage(peer: room, direction: .incoming, text: body, date: date, encrypted: false,
                               nick: "\(nick) (лично)"))
        }
    }

    #if DEBUG
    /// Прогоняет строфу через обычные обработчики: для проверки без сервера (см. PsiDemo).
    func debugReceive(_ xml: String) {
        guard let element = try? DDXMLElement(xmlString: xml) else { return }
        switch element.name {
        case "presence":
            handlePresence(XMPPPresence(from: element))
        case "iq":
            let iq = XMPPIQ(from: element)
            guard !isForgedRosterIQ(iq, own: myJID) else { return }
            iq.child("query", ns: "jabber:iq:roster")?.elements(forName: "item").forEach(applyRosterItem)
        default:
            handleMessage(XMPPMessage(from: element))
        }
    }

    func debugJoin(room: String, nick: String) { join(room: room, nick: nick) }
    #endif

    // MARK: Блокировка и жалобы

    /// Блокирует локально и на сервере (XEP-0191); жалоба уходит администратору сервера (XEP-0377).
    func block(_ jid: String, report: ReportReason? = nil) {
        blocked.insert(jid)
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "jid", stringValue: jid)
        if let report {
            let r = DDXMLElement(name: "report", xmlns: NS.reporting)
            r.addAttribute(withName: "reason", stringValue: report.urn)
            item.addChild(r)
        }
        let block = DDXMLElement(name: "block", xmlns: NS.blocking)
        block.addChild(item)
        sendSet(block)
    }

    func unblock(_ jid: String) {
        blocked.remove(jid)
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "jid", stringValue: jid)
        let unblock = DDXMLElement(name: "unblock", xmlns: NS.blocking)
        unblock.addChild(item)
        sendSet(unblock)
    }

    private func sendSet(_ child: DDXMLElement) {
        guard stream.isConnected else { return }
        stream.send(XMPPIQ(type: "set", to: nil, elementID: UUID().uuidString, child: child))
    }

    // MARK: Push (XEP-0357)

    /// Включается, только если задан JID push-сервиса: без него и без entitlement aps-environment ничего не происходит.
    private var pushService: String? {
        UserDefaults.standard.string(forKey: "account.pushService").flatMap { $0.isEmpty ? nil : $0 }
    }

    private func registerForPush() {
        guard pushService != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    private func sendPushEnable() {
        guard let pushService, let token = UserDefaults.standard.string(forKey: "push.token") else { return }
        let enable = DDXMLElement(name: "enable", xmlns: NS.push)
        enable.addAttribute(withName: "jid", stringValue: pushService)
        enable.addAttribute(withName: "node", stringValue: token)
        sendSet(enable)
    }

    private func discoverFeatures(of jid: XMPPJID?) {
        guard let jid else { return }
        let query = DDXMLElement(name: "query", xmlns: NS.discoInfo)
        let id = UUID().uuidString
        discoRequests[id] = jid.bare
        stream.send(XMPPIQ(type: "get", to: jid, elementID: id, child: query))
    }

    // MARK: Ростер

    /// Группы в порядке Psi+: по алфавиту, «Без группы» в конце.
    var groupedContacts: [(group: String, contacts: [Contact])] {
        var dict: [String: [Contact]] = [:]
        for c in contacts.values where !blocked.contains(c.jid) {
            let groups = c.groups.isEmpty ? ["Без группы"] : c.groups
            for g in groups { dict[g, default: []].append(c) }
        }
        return dict
            .map { (group: $0.key, contacts: $0.value.sorted(by: Self.rosterOrder)) }
            .sorted { a, b in
                if a.group == "Без группы" { return false }
                if b.group == "Без группы" { return true }
                return a.group.localizedCaseInsensitiveCompare(b.group) == .orderedAscending
            }
    }

    private static func rosterOrder(_ a: Contact, _ b: Contact) -> Bool {
        if a.show.sortOrder != b.show.sortOrder { return a.show.sortOrder < b.show.sortOrder }
        return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }
}

// MARK: - XMPPStreamDelegate

extension XMPPClient: XMPPStreamDelegate {
    nonisolated func xmppStream(_ sender: XMPPStream, willSecureWithSettings settings: NSMutableDictionary) {
        settings[GCDAsyncSocketManuallyEvaluateTrust] = NSNumber(value: true)
        settings[GCDAsyncSocketSSLProtocolVersionMin] = NSNumber(value: SSLProtocol.tlsProtocol12.rawValue)
    }

    /// Обычная проверка цепочки и имени; если не прошла — только сертификат, закреплённый за этим доменом
    /// (как override-certificate в Psi+), сравнение по SHA-256 всего сертификата.
    nonisolated func xmppStream(_ sender: XMPPStream, didReceive trust: SecTrust,
                                completionHandler: @escaping (Bool) -> Void) {
        guard let domain = sender.myJID?.domain else { completionHandler(false); return }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, domain as CFString))
        let store = KeyStore.shared
        if SecTrustEvaluateWithError(trust, nil) {
            // Сервер снова проходит проверку: старый сертификат больше не должен приниматься.
            if store.certPin != nil { store.certPin = nil }
            setTLSPinned(false)
            completionHandler(true)
            return
        }

        guard let pin = store.certPin, pin.domain == domain.lowercased(),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { completionHandler(false); return }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        let matches = digest.map { String(format: "%02x", $0) }.joined() == pin.sha256
        setTLSPinned(matches)
        completionHandler(matches)
    }

    private nonisolated func setTLSPinned(_ value: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.tlsPinned = value } }
    }

    /// Обновления ростера принимаются только от своего аккаунта или сервера без from (RFC 6121, 2.1.6).
    nonisolated func xmppStream(_ sender: XMPPStream, willReceive iq: XMPPIQ) -> XMPPIQ? {
        isForgedRosterIQ(iq, own: sender.myJID?.bare) ? nil : iq
    }

    nonisolated func xmppStreamDidConnect(_ sender: XMPPStream) {
        MainActor.assumeIsolated {
            // Только SCRAM: при PLAIN и DIGEST-MD5 сервер не доказывает, что знает пароль, а PLAIN ещё и передаёт его.
            guard sender.supportsSCRAMSHA1Authentication else {
                disconnectReason = "Сервер не поддерживает безопасный вход (SCRAM)"
                sender.disconnect()
                return
            }
            do { try sender.authenticate(CheckedSCRAM(stream: sender, password: password)) }
            catch { state = .error(error.localizedDescription) }
        }
    }

    nonisolated func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        MainActor.assumeIsolated {
            state = .connected
            sendPresence(.online)
            // Блокировки, сделанные без связи, доходят до сервера при следующем входе.
            for jid in blocked { block(jid) }
            for room in conferences.keys { enter(room) }
            discoverFeatures(of: sender.myJID?.bareJID)
            discoverFeatures(of: sender.myJID?.domainJID)
            registerForPush()
        }
    }

    nonisolated func xmppStream(_ sender: XMPPStream, didReceive iq: XMPPIQ) -> Bool {
        MainActor.assumeIsolated {
            // Ответ принимается только на свой запрос и только от того, кого спрашивали.
            guard let id = iq.elementID, let asked = discoRequests[id],
                  iq.isResultIQ || iq.isErrorIQ, iq.from == nil || iq.from?.bare == asked else { return false }
            discoRequests[id] = nil
            if iq.isResultIQ, let query = iq.child("query", ns: NS.discoInfo) {
                let features = query.elements(forName: "feature").compactMap { $0.attributeStringValue(forName: "var") }
                serverFeatures.formUnion(features)
            }
            return true
        }
    }

    nonisolated func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: DDXMLElement) {
        MainActor.assumeIsolated { state = .error("Ошибка авторизации") }
    }

    nonisolated func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
        MainActor.assumeIsolated {
            if let disconnectReason {
                state = .error(disconnectReason)
            } else if let error {
                state = .error(error.localizedDescription)
            } else {
                state = .disconnected
            }
            disconnectReason = nil
            rosterLoaded = false
            discoRequests = [:]
            for k in contacts.keys { contacts[k]?.show = .offline }
            for k in conferences.keys {
                conferences[k]?.joined = false
                conferences[k]?.occupants = [:]
            }
            let next = connectAfterDisconnect
            connectAfterDisconnect = nil
            next?()
        }
    }

    nonisolated func xmppStream(_ sender: XMPPStream, didReceive presence: XMPPPresence) {
        MainActor.assumeIsolated { handlePresence(presence) }
    }

    nonisolated func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
        MainActor.assumeIsolated { handleMessage(message) }
    }

    private func handlePresence(_ presence: XMPPPresence) {
        if let room = presence.from?.bare, conferences[room] != nil {
            handleRoomPresence(presence, room: room)
            return
        }
        guard let from = presence.from?.bare, from != myJID, !blocked.contains(from) else { return }
        let type = presence.type ?? "available"
        guard type == "available" || type == "unavailable" else { return }

        // Посторонний не должен появляться в ростере от одного presence.
        guard var c = contacts[from] else {
            if !rosterLoaded, pendingPresence[from] != nil || pendingPresence.count < Self.pendingLimit {
                pendingPresence[from] = presence
            }
            return
        }
        let serial = presenceSerial[from, default: 0] + 1
        presenceSerial[from] = serial
        c.show = PresenceShow(xmppShow: presence.show, available: type == "available")
        c.status = presence.status

        guard let sig = presence.child("x", ns: NS.signed)?.stringValue else {
            c.signatureValid = false
            c.signedKeyID = nil
            contacts[from] = c
            return
        }
        contacts[from] = c
        // Проверка подписи не должна тормозить интерфейс при потоке presence.
        let status = presence.status
        let pgp = pgp
        Task.detached {
            let valid = pgp.verifyPresence(status: status ?? "", signature: sig, from: from)
            let keyID = valid ? KeyStore.shared.publicKey(for: from).flatMap { try? pgp.keyID(ofArmored: $0) } : nil
            await MainActor.run {
                guard self.presenceSerial[from] == serial else { return }
                self.contacts[from]?.signatureValid = valid
                self.contacts[from]?.signedKeyID = keyID
            }
        }
    }

    private func handleMessage(_ message: XMPPMessage) {
        if let room = message.from?.bare, conferences[room] != nil {
            handleRoomMessage(message, room: room)
            return
        }
        guard let from = message.from?.bare, !blocked.contains(from) else { return }
        // Незнакомые не пишут на диск; сообщение покажем, если контакт появится в ростере.
        guard contacts[from] != nil || from == myJID else {
            // Новые важнее старых: посторонний не должен вытеснить очередь своим потоком.
            if !rosterLoaded {
                if pendingMessages.count >= Self.pendingLimit { pendingMessages.removeFirst() }
                pendingMessages.append(message)
            }
            return
        }
        let date = directDate(of: message)

        // Отказ доставки содержит наш же текст, это не сообщение контакта.
        if message.type == "error" {
            append(ChatMessage(peer: from, direction: .system, text: "Сообщение не доставлено",
                               date: date, encrypted: false))
            return
        }

        if let payload = message.child("x", ns: NS.encrypted)?.stringValue {
            pgpExpected.insert(from)
            do {
                let result = try pgp.decrypt(payload, senderKey: KeyStore.shared.publicKey(for: from))
                var m = ChatMessage(peer: from, direction: .incoming, text: result.text, date: date, encrypted: true)
                m.verified = result.verified
                append(m)
                // Собеседник пишет шифрованно — включаем замочек в ответ, как Psi+.
                pgpDisabled.remove(from)
            } catch {
                var m = ChatMessage(peer: from, direction: .incoming,
                                    text: "Не удалось расшифровать: \(error.localizedDescription)",
                                    date: date, encrypted: true)
                m.decryptFailed = true
                append(m)
            }
            return
        }

        guard let body = message.body, !body.isEmpty else { return }
        append(ChatMessage(peer: from, direction: .incoming, text: body, date: date, encrypted: false))
    }
}

// MARK: - XMPPRosterDelegate

extension XMPPClient: XMPPRosterDelegate {
    nonisolated func xmppRoster(_ sender: XMPPRoster, didReceiveRosterItem item: DDXMLElement) {
        MainActor.assumeIsolated { applyRosterItem(item) }
    }

    nonisolated func xmppRosterDidEndPopulating(_ sender: XMPPRoster) {
        MainActor.assumeIsolated {
            rosterLoaded = true
            pendingPresence = [:]
            pendingMessages = []
        }
    }

    private func applyRosterItem(_ item: DDXMLElement) {
        // Тот же вид, что у from в presence и сообщениях: иначе контакт с заглавными буквами в JID не совпадёт.
        guard let jid = item.attributeStringValue(forName: "jid").flatMap({ XMPPJID(string: $0)?.bare }) else { return }
        let subscription = item.attributeStringValue(forName: "subscription") ?? "none"
        if subscription == "remove" { contacts[jid] = nil; return }
        let groups = item.elements(forName: "group").compactMap { $0.stringValue }
        var c = contacts[jid] ?? Contact(jid: jid, name: nil, groups: [], subscription: subscription)
        c.name = item.attributeStringValue(forName: "name")
        c.groups = groups
        c.subscription = subscription
        contacts[jid] = c

        if let presence = pendingPresence.removeValue(forKey: jid) { handlePresence(presence) }
        let waiting = pendingMessages.filter { $0.from?.bare == jid }
        pendingMessages.removeAll { $0.from?.bare == jid }
        waiting.forEach(handleMessage)
    }
}

/// SCRAM из XMPPFramework плюс то, чего она не проверяет (RFC 5802): nonce сервера начинается с нашего,
/// а число итераций не подвешивает приложение. Подпись сервера библиотека проверяет сама.
final class CheckedSCRAM: XMPPSCRAMSHA1Authentication {
    private static let maxIterations = 1_000_000
    private var challengeChecked = false

    override func handleAuth(_ auth: DDXMLElement) -> XMPPHandleAuthResponse {
        if !challengeChecked, auth.name == "challenge" {
            challengeChecked = true
            guard isValid(challenge: auth) else { return .failed }
        }
        return super.handleAuth(auth)
    }

    private func isValid(challenge: DDXMLElement) -> Bool {
        // clientNonce — приватное свойство XMPPFramework. Если его переименуют при обновлении, вход не пройдёт,
        // но приложение не упадёт на исключении KVC.
        guard responds(to: NSSelectorFromString("clientNonce")),
              let text = challenge.stringValue, let data = Data(base64Encoded: text),
              let decoded = String(data: data, encoding: .utf8),
              let nonce = value(forKey: "clientNonce") as? String else { return false }
        var fields: [String: String] = [:]
        for part in decoded.split(separator: ",") where part.dropFirst().first == "=" {
            fields[String(part.prefix(1))] = String(part.dropFirst(2))
        }
        guard let combined = fields["r"], combined.hasPrefix(nonce), combined.count > nonce.count,
              let iterations = fields["i"].flatMap({ Int($0) }) else { return false }
        return iterations <= Self.maxIterations
    }
}

private func isForgedRosterIQ(_ iq: XMPPIQ, own: String?) -> Bool {
    guard iq.child("query", ns: "jabber:iq:roster") != nil, let from = iq.from?.bare else { return false }
    return from != own
}

// MARK: - XML helpers

extension DDXMLElement {
    /// Первый дочерний элемент с данным именем и пространством имён.
    func child(_ name: String, ns: String) -> DDXMLElement? {
        elements(forLocalName: name, uri: ns).first
    }
}
