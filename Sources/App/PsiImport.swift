#if DEBUG
import Foundation

/// Разовый перенос настроек из Psi+ (scripts/import-psi.py): файл кладётся в Documents через devicectl
/// и удаляется сразу после чтения. В отчёт секреты не попадают. Только в Debug-сборках.
enum PsiImport {
    private struct Payload: Decodable {
        let jid: String
        let password: String
        let secretKey: String
        let passphrase: String
        let contactKeys: [String: String]
        let certPin: String?
        let pgpDisabled: [String]
        let history: [HistoryItem]
    }

    private struct HistoryItem: Decodable {
        let peer: String
        let text: String
        let date: Double
        let outgoing: Bool
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private static var report: [String: String] = [:]

    static func run() {
        let file = documents.appendingPathComponent("psi-import.json")
        guard let data = try? Data(contentsOf: file) else { return }
        try? FileManager.default.removeItem(at: file)
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else {
            report["error"] = "bad payload"
            writeReport()
            return
        }

        UserDefaults.standard.set(p.jid, forKey: "account.jid")
        UserDefaults.standard.set(p.pgpDisabled, forKey: "pgp.disabledChats")
        Credentials.password = p.password
        let store = KeyStore.shared
        let pgp = PGPService.shared
        store.certPin = p.certPin.map { (domain(of: p.jid), $0) }
        store.ownSecretKey = p.secretKey
        store.ownPassphrase = p.passphrase
        pgp.resetCache()
        for (jid, key) in p.contactKeys { store.setPublicKey(key, for: jid) }

        var historyTotal = 0
        for (peer, items) in Dictionary(grouping: p.history, by: \.peer) {
            let imported = items.map {
                ChatMessage(peer: peer, direction: $0.outgoing ? .outgoing : .incoming, text: $0.text,
                            date: Date(timeIntervalSince1970: $0.date), encrypted: false)
            }
            historyTotal += HistoryStore.shared.merge(imported, peer: peer)
        }
        report["history"] = String(historyTotal)

        report["jid"] = p.jid
        report["contactKeys"] = String(p.contactKeys.count)
        report["ownKey"] = check { try pgp.fingerprint(ofArmored: p.secretKey) }
        report["sign"] = check { _ = try pgp.signPresence(status: "test"); return "ok" }
        if let jid = p.contactKeys.keys.sorted().first {
            report["encryptDecrypt"] = check {
                try pgp.decrypt(try pgp.encrypt("test", to: jid), senderKey: nil).text == "test" ? "ok" : "mismatch"
            }
        }
        writeReport()
    }

    private static func domain(of jid: String) -> String {
        jid.components(separatedBy: "@").last?.lowercased() ?? ""
    }

    /// Дописывает в отчёт результат подключения, если при этом запуске был импорт.
    @MainActor
    static func reportConnection(_ client: XMPPClient) async {
        guard !report.isEmpty else { return }
        for _ in 0..<30 where client.state == .connecting {
            try? await Task.sleep(for: .seconds(1))
        }
        // Ростер приходит уже после авторизации.
        try? await Task.sleep(for: .seconds(3))
        report["connection"] = "\(client.state)"
        report["contacts"] = String(client.contacts.count)
        report["serverPush"] = String(client.serverFeatures.contains("urn:xmpp:push:0"))
        report["serverBlocking"] = String(client.serverFeatures.contains("urn:xmpp:blocking"))
        report["serverFeatureCount"] = String(client.serverFeatures.count)
        for jid in client.contacts.keys where KeyStore.shared.publicKey(for: jid) != nil {
            let c = client.contacts[jid]
            report["pgp \(jid)"] = "lock=\(client.isEncrypted(jid)) show=\(c?.show.rawValue ?? "?") signatureValid=\(c?.signatureValid == true)"
        }
        writeReport()
    }

    private static func check(_ body: () throws -> String) -> String {
        do { return try body() } catch { return "error: \(error.localizedDescription)" }
    }

    private static func writeReport() {
        let file = documents.appendingPathComponent("psi-import-status.json")
        if let data = try? JSONEncoder().encode(report) { try? data.write(to: file) }
    }
}
#endif
