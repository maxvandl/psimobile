import Foundation

/// Статусы как в Psi+: порядок совпадает с сортировкой ростера.
enum PresenceShow: String, CaseIterable, Identifiable {
    case chat, online, away, xa, dnd, offline
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Готов болтать"
        case .online: return "В сети"
        case .away: return "Отошёл"
        case .xa: return "Недоступен"
        case .dnd: return "Не беспокоить"
        case .offline: return "Не в сети"
        }
    }

    /// Значение <show/> в XMPP (nil для online/offline).
    var xmppShow: String? {
        switch self {
        case .chat, .away, .xa, .dnd: return rawValue
        default: return nil
        }
    }

    var sortOrder: Int {
        switch self {
        case .chat: return 0
        case .online: return 1
        case .away: return 2
        case .xa: return 3
        case .dnd: return 4
        case .offline: return 5
        }
    }

    init(xmppShow: String?, available: Bool) {
        guard available else { self = .offline; return }
        switch xmppShow {
        case "chat": self = .chat
        case "away": self = .away
        case "xa": self = .xa
        case "dnd": self = .dnd
        default: self = .online
        }
    }
}

struct Contact: Identifiable, Hashable {
    let jid: String
    var name: String?
    var groups: [String]
    var subscription: String
    var show: PresenceShow = .offline
    var status: String?
    /// Key ID из подписанного presence (XEP-0027).
    var signedKeyID: String?
    /// Подпись presence проверена известным ключом контакта.
    var signatureValid: Bool = false

    var id: String { jid }
    var displayName: String { (name?.isEmpty == false ? name! : jid) }
}

struct ChatMessage: Identifiable, Hashable, Codable {
    enum Direction: String, Codable { case incoming, outgoing, system }

    var id = UUID()
    let peer: String
    let direction: Direction
    let text: String
    let date: Date
    let encrypted: Bool
    /// Пришло зашифрованным, но расшифровать не удалось.
    var decryptFailed: Bool = false
    /// Ник автора в конференции.
    var nick: String?
    /// Подпись проверена ключом контакта. Optional: в старых записях истории этого поля нет.
    var verified: Bool?
}

/// Конференция (XEP-0045). Между запусками хранятся только адрес и ник.
struct Conference: Identifiable, Hashable {
    let jid: String
    var nick: String
    var joined = false
    var error: String?
    var occupants: [String: PresenceShow] = [:]
    /// Настоящие JID участников, если комната их раскрывает.
    var occupantJIDs: [String: String] = [:]

    var id: String { jid }
    var name: String { jid.components(separatedBy: "@")[0] }
}
