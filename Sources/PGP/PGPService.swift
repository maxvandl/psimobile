import Foundation
import Psipgp

enum PGPError: LocalizedError {
    case noOwnKey, noContactKey(String), go(String)
    var errorDescription: String? {
        switch self {
        case .noOwnKey: return "Не задан свой секретный ключ"
        case .noContactKey(let jid): return "нет ключа \(jid). Назначьте ключ или выключите шифрование в меню замка"
        case .go(let msg): return msg
        }
    }
}

/// PGP по XEP-0027 (Current Jabber OpenPGP Usage), совместимо с Psi+/Gajim.
///
/// - сообщение: тело шифруется на ключ собеседника и на свой; в <x xmlns='jabber:x:encrypted'>
///   кладётся ASCII-armor без заголовка/футера.
/// - presence: detached-подпись текста статуса в <x xmlns='jabber:x:signed'>.
final class PGPService {
    static let shared = PGPService()
    private let store = KeyStore.shared

    // MARK: Ключи

    /// Отпечаток / key ID ключа (для отображения и проверки).
    func fingerprint(ofArmored armored: String) throws -> String {
        var err: NSError?
        let value = PsipgpFingerprint(armored, &err)
        if let err { throw PGPError.go(err.localizedDescription) }
        return value.uppercased()
    }

    func keyID(ofArmored armored: String) throws -> String {
        var err: NSError?
        let value = PsipgpKeyID(armored, &err)
        if let err { throw PGPError.go(err.localizedDescription) }
        return value.uppercased()
    }

    /// Проверяет, что секретный ключ открывается паролем.
    func validateOwnKey(armored: String, passphrase: String) throws {
        _ = try openKey(armored, passphrase: passphrase)
    }

    // MARK: Шифрование (XEP-0027)

    /// Возвращает содержимое для <x xmlns='jabber:x:encrypted'>.
    func encrypt(_ plaintext: String, to jid: String) throws -> String {
        guard let contactArmored = store.publicKey(for: jid) else { throw PGPError.noContactKey(jid) }
        // Шифруем и на себя, чтобы читать свои сообщения в истории/на других клиентах.
        var err: NSError?
        let armored = PsipgpEncrypt(plaintext, contactArmored, store.ownSecretKey ?? "", &err)
        if let err { throw PGPError.go(err.localizedDescription) }
        return Armor.strip(armored)
    }

    /// XEP-0027 не требует подписи, поэтому её отсутствие не ошибка: `verified` лишь говорит,
    /// что сообщение подписано ключом `senderKey`. Без подписи автора подтверждает только сервер.
    func decrypt(_ xepPayload: String, senderKey: String?) throws -> (text: String, verified: Bool) {
        let armored = Armor.wrap(xepPayload, type: "MESSAGE")
        let result = try unlockedOwnKey().decrypt(armored, sender: senderKey ?? "")
        return (result.text, result.verified)
    }

    // MARK: Подпись presence (XEP-0027)

    /// Подписывает текст статуса (пустая строка, если статуса нет), возвращает содержимое для <x xmlns='jabber:x:signed'>.
    func signPresence(status: String) throws -> String {
        var err: NSError?
        let armored = try unlockedOwnKey().sign(status, error: &err)
        if let err { throw PGPError.go(err.localizedDescription) }
        return Armor.strip(armored)
    }

    /// Проверка подписи presence известным ключом контакта.
    func verifyPresence(status: String, signature xepPayload: String, from jid: String) -> Bool {
        guard let contactArmored = store.publicKey(for: jid) else { return false }
        return PsipgpVerify(status, Armor.wrap(xepPayload, type: "SIGNATURE"), contactArmored)
    }

    // MARK: Внутреннее

    private var cachedOwnKey: PsipgpOwnKey?

    func resetCache() { cachedOwnKey = nil }

    private func unlockedOwnKey() throws -> PsipgpOwnKey {
        if let cachedOwnKey { return cachedOwnKey }
        guard let armored = store.ownSecretKey else { throw PGPError.noOwnKey }
        let key = try openKey(armored, passphrase: store.ownPassphrase ?? "")
        cachedOwnKey = key
        return key
    }

    private func openKey(_ armored: String, passphrase: String) throws -> PsipgpOwnKey {
        var err: NSError?
        guard let key = PsipgpNewOwnKey(armored, passphrase.data(using: .utf8), &err) else {
            throw PGPError.go(err?.localizedDescription ?? "Не удалось прочитать ключ")
        }
        return key
    }
}

/// XEP-0027 передаёт ASCII-armor без строк BEGIN/END и заголовков.
enum Armor {
    static func strip(_ armored: String) -> String {
        var lines = armored.components(separatedBy: .newlines)
        lines.removeAll { $0.hasPrefix("-----BEGIN") || $0.hasPrefix("-----END") }
        // Заголовки (Version:, Comment: ...) идут до первой пустой строки.
        if let blank = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[..<blank].allSatisfy({ $0.contains(": ") }) {
            lines.removeSubrange(...blank)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func wrap(_ body: String, type: String) -> String {
        "-----BEGIN PGP \(type)-----\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n-----END PGP \(type)-----\n"
    }
}
