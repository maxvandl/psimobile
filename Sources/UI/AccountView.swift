import SwiftUI
import Security
import UniformTypeIdentifiers

/// Настройки аккаунта и своего PGP-ключа (аналог «Изменить учётную запись» в Psi+).
struct AccountView: View {
    @EnvironmentObject var client: XMPPClient
    @Environment(\.dismiss) private var dismiss

    @AppStorage("account.jid") private var savedJID = ""
    @State private var jid = ""
    @AppStorage("account.host") private var host = ""
    @AppStorage("account.port") private var port = ""
    @AppStorage("account.pushService") private var pushService = ""
    @State private var password = ""

    @State private var secretKey = ""
    @State private var passphrase = ""
    @State private var keyInfo: String?
    @State private var keyError: String?
    @State private var importing = false
    @State private var confirmSwitch = false
    @State private var confirmWipe = false

    private var isOtherAccount: Bool {
        !savedJID.isEmpty && savedJID.lowercased() != jid.trimmingCharacters(in: .whitespaces).lowercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Учётная запись") {
                    TextField("JID (user@server)", text: $jid)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                    SecureField("Пароль", text: $password)
                }
                Section("Соединение (необязательно)") {
                    TextField("Хост", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Порт", text: $port).keyboardType(.numberPad)
                    if client.tlsPinned {
                        Text("Сертификат сервера не прошёл проверку и принят только потому, что закреплён. Его нужно обновить на сервере.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button(client.state == .connected ? "Переподключиться" : "Подключиться") {
                        if isOtherAccount { confirmSwitch = true } else { connect() }
                    }
                    .disabled(jid.isEmpty || password.isEmpty)
                }

                Section {
                    TextEditor(text: $secretKey)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(minHeight: 120)
                    Button("Импорт из файла (.asc)…") { importing = true }
                    SecureField("Пароль ключа", text: $passphrase)
                    Button("Сохранить ключ", action: saveKey)
                        .disabled(secretKey.isEmpty)
                    if let keyInfo { Text(keyInfo).font(.system(.footnote, design: .monospaced)) }
                    if let keyError { Text(keyError).foregroundStyle(.red) }
                } header: {
                    Text("Мой ключ OpenPGP")
                } footer: {
                    Text("Экспорт с компьютера: gpg --export-secret-keys --armor KEYID > key.asc. Ключ и пароль хранятся в Keychain только на этом устройстве.")
                }

                Section {
                    TextField("JID push-сервиса", text: $pushService)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Уведомления (необязательно)")
                } footer: {
                    Text(client.serverFeatures.contains("urn:xmpp:push:0")
                         ? "Сервер поддерживает push (XEP-0357)."
                         : "Без push сообщения приходят, только пока приложение открыто.")
                }

                if !client.blocked.isEmpty {
                    Section("Заблокированные") {
                        ForEach(client.blocked.sorted(), id: \.self) { jid in
                            HStack {
                                Text(jid).lineLimit(1)
                                Spacer()
                                Button("Разблокировать") { client.unblock(jid) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("О приложении") {
                    if let support = AppInfo.supportURL {
                        Link("Написать разработчику", destination: support)
                    }
                    NavigationLink("Лицензии") { LicensesView() }
                }

                Section {
                    Button("Удалить аккаунт с устройства", role: .destructive) { confirmWipe = true }
                } footer: {
                    Text("Удаляются пароль, ключи и вся история на этом устройстве. Сам аккаунт на сервере останется.")
                }
            }
            .navigationTitle("Аккаунт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .confirmationDialog("Сменить аккаунт? Пароль, ключи и история прежнего аккаунта будут удалены с устройства.",
                                isPresented: $confirmSwitch, titleVisibility: .visible) {
                Button("Удалить и сменить", role: .destructive, action: switchAccount)
            }
            .confirmationDialog("Удалить пароль, ключи и всю историю с этого устройства?",
                                isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    client.wipeAccount()
                    dismiss()
                }
            }
            .onAppear {
                jid = savedJID
                password = Credentials.password ?? ""
                if let k = KeyStore.shared.ownSecretKey {
                    keyInfo = (try? PGPService.shared.fingerprint(ofArmored: k)).map { "Ключ: \($0)" }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data]) { result in
                guard case .success(let url) = result,
                      url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                secretKey = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
    }

    private func connect() {
        savedJID = jid
        Credentials.password = password
        client.disconnect()
        client.connect(jid: jid, password: password, host: host.isEmpty ? nil : host, port: UInt16(port))
        dismiss()
    }

    /// Настройки нового аккаунта уже на экране, а стирание очищает и их.
    private func switchAccount() {
        let (newHost, newPort) = (host, port)
        client.wipeAccount()
        (host, port) = (newHost, newPort)
        connect()
    }

    private func saveKey() {
        do {
            try PGPService.shared.validateOwnKey(armored: secretKey, passphrase: passphrase)
            KeyStore.shared.ownSecretKey = secretKey
            KeyStore.shared.ownPassphrase = passphrase
            PGPService.shared.resetCache()
            keyInfo = "Ключ: \(try PGPService.shared.fingerprint(ofArmored: secretKey))"
            keyError = nil
            secretKey = ""
            passphrase = ""
            // Переотправить presence с подписью.
            client.setStatus(text: client.myStatus)
        } catch {
            keyError = error.localizedDescription
        }
    }
}

enum AppInfo {
    /// Контакт для обращений и жалоб, обязателен для App Store. Пока не задан, раздел скрыт.
    static let supportURL: URL? = nil
}

/// Уведомления лицензий компонентов (Resources/Licenses.txt).
struct LicensesView: View {
    private var text: String {
        Bundle.main.url(forResource: "Licenses", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .navigationTitle("Лицензии")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Пароль аккаунта — тоже в Keychain, рядом с PGP.
enum Credentials {
    private static let service = "am.local.psimobile.account"

    static var password: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
            SecItemDelete(q as CFDictionary)
            guard let newValue, let d = newValue.data(using: .utf8) else { return }
            var add = q
            add[kSecValueData as String] = d
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
