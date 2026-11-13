import Foundation
import Security
import UIKit

/// Хранение ключей в Keychain.
/// - свой секретный ключ + пароль к нему (только на этом устройстве, пока оно разблокировано)
/// - публичные ключи контактов, привязанные к JID (как «Назначить ключ» в Psi+)
final class KeyStore {
    static let shared = KeyStore()
    private static let services = ["am.local.psimobile.pgp", "am.local.psimobile.account"]
    private let service = services[0]

    private enum Account {
        static let secretKey = "own.secret"
        static let passphrase = "own.passphrase"
        static let certPin = "tls.certPin"
        static func contact(_ jid: String) -> String { "contact.\(jid.lowercased())" }
    }

    // MARK: Свой ключ

    var ownSecretKey: String? {
        get { read(Account.secretKey) }
        set { write(Account.secretKey, newValue) }
    }

    var ownPassphrase: String? {
        get { read(Account.passphrase) }
        set { write(Account.passphrase, newValue) }
    }

    // MARK: Ключи контактов

    func publicKey(for jid: String) -> String? { read(Account.contact(jid)) }
    func setPublicKey(_ armored: String?, for jid: String) { write(Account.contact(jid), armored) }

    /// false, только если ключа точно нет: при ошибке Keychain шифрование не должно молча отключаться.
    func mayHavePublicKey(for jid: String) -> Bool {
        SecItemCopyMatching(baseQuery(Account.contact(jid)) as CFDictionary, nil) != errSecItemNotFound
    }

    // MARK: Закреплённый сертификат

    /// Сертификат, принятый вручную (аналог override-certificate в Psi+), привязан к одному домену.
    /// В Keychain, а не в UserDefaults: настройки попадают в резервную копию, и подменённый пин
    /// позволил бы подставить свой сертификат.
    var certPin: (domain: String, sha256: String)? {
        get {
            let parts = read(Account.certPin)?.components(separatedBy: "\n") ?? []
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
        set { write(Account.certPin, newValue.map { "\($0.domain.lowercased())\n\($0.sha256.lowercased())" }) }
    }

    /// Прежние версии держали пин в UserDefaults, иногда без домена: переносим в Keychain, привязав к аккаунту.
    static func migratePin() {
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: "account.certPin")
            defaults.removeObject(forKey: "account.certPinDomain")
        }
        guard let pin = defaults.string(forKey: "account.certPin") else { return }
        let domain = defaults.string(forKey: "account.certPinDomain")
            ?? defaults.string(forKey: "account.jid")?.components(separatedBy: "@").last?.lowercased()
        if let domain, !domain.isEmpty { shared.certPin = (domain, pin) }
    }

    // MARK: Keychain

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String?) {
        let q = baseQuery(account)
        SecItemDelete(q as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Записи, созданные раньше с доступом «после первой разблокировки», переводит на «пока разблокировано».
    static func migrateAccessibility() {
        let flag = "keychain.whenUnlocked"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let results = services.map { service -> OSStatus in
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service]
            let update = [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            return SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        if results.allSatisfy({ $0 == errSecSuccess || $0 == errSecItemNotFound }) {
            UserDefaults.standard.set(true, forKey: flag)
        }
    }

    static func deleteAll() {
        for service in services {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service]
            SecItemDelete(query as CFDictionary)
        }
    }

    /// Keychain может пережить удаление приложения, а настройки нет: после переустановки секреты прежней установки стираются.
    /// Пока данные закрыты, настройки могут читаться пустыми, поэтому без разблокировки ничего не делаем.
    @MainActor
    static func clearAfterReinstall() {
        let flag = "keychain.owned"
        let defaults = UserDefaults.standard
        guard UIApplication.shared.isProtectedDataAvailable, !defaults.bool(forKey: flag) else { return }
        if defaults.string(forKey: "account.jid") == nil { deleteAll() }
        defaults.set(true, forKey: flag)
    }
}
