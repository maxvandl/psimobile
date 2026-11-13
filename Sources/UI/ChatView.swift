import SwiftUI
import UniformTypeIdentifiers

/// Окно чата в стиле Psi+: «[чч:мм:сс] <ник> текст», цветные ники, замочек PGP в тулбаре.
struct ChatView: View {
    let jid: String
    @EnvironmentObject var client: XMPPClient
    @State private var input = ""
    @State private var keySheet = false
    @State private var confirmBlock = false
    @State private var confirmReport = false
    @Environment(\.dismiss) private var dismiss

    private var contact: Contact? { client.contacts[jid] }
    private var log: [ChatMessage] { client.messages[jid] ?? [] }
    private var pgpOn: Bool { client.isEncrypted(jid) }
    private var hasKey: Bool { KeyStore.shared.publicKey(for: jid) != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log) { msg in
                            ChatLine(msg: msg,
                                     localNick: "Я",
                                     remoteNick: contact?.displayName ?? jid)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .defaultScrollAnchor(.bottom)
                .background(Color.white)
                .onChange(of: log.count) {
                    if let last = log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            inputBar
        }
        .onAppear { client.loadHistory(jid) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(contact?.displayName ?? jid).font(.headline).lineLimit(1)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Замок: зашифровано. Галочка: подпись отправителя проверена. Без галочки автора подтверждает только сервер.") {}
                    Button(pgpOn ? "Выключить шифрование" : "Включить шифрование (PGP)") {
                        if pgpOn || hasKey { client.togglePGP(for: jid) } else { keySheet = true }
                    }
                    Button("Назначить ключ OpenPGP…") { keySheet = true }
                    Button("Заблокировать", role: .destructive) { confirmBlock = true }
                    Button("Пожаловаться…", role: .destructive) { confirmReport = true }
                        .disabled(client.state != .connected)
                } label: {
                    Image(systemName: pgpOn ? "lock.fill" : "lock.open")
                        .foregroundStyle(pgpOn ? Color(hex: 0x2EA82E) : .secondary)
                }
            }
        }
        .sheet(isPresented: $keySheet) { AssignKeyView(jid: jid) }
        // Строка, а не литерал с подстановкой: литерал стал бы LocalizedStringKey, и JID разобрался бы как Markdown.
        .confirmationDialog(Text(verbatim: "Заблокировать \(jid)? Сообщения от контакта перестанут приходить."),
                            isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Заблокировать", role: .destructive) {
                client.block(jid)
                dismiss()
            }
        }
        .confirmationDialog("Жалоба уйдёт администратору сервера, контакт будет заблокирован.",
                            isPresented: $confirmReport, titleVisibility: .visible) {
            ForEach(ReportReason.allCases) { reason in
                Button(reason.title, role: .destructive) {
                    client.block(jid, report: reason)
                    dismiss()
                }
            }
        }
    }

    /// Шапка как в Psi+: иконка статуса, JID и текст статуса.
    private var header: some View {
        HStack(spacing: 6) {
            StatusIcon(show: contact?.show ?? .offline)
            VStack(alignment: .leading, spacing: 0) {
                Text(jid).font(.system(size: 13, weight: .semibold))
                if let s = contact?.status, !s.isEmpty {
                    Text(s).font(.system(size: 12)).foregroundStyle(PsiTheme.statusText).lineLimit(1)
                }
            }
            Spacer()
            if contact?.signatureValid == true {
                Label("подпись", systemImage: "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0xB8860B))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(PsiTheme.groupBack)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(pgpOn ? "Сообщение" : "Сообщение без шифрования", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: 0xA0A0A0)))
            Button {
                let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                client.send(text, to: jid)
                input = ""
            } label: {
                Text("Отпр.").bold()
            }
            .buttonStyle(.borderedProminent)
            .tint(pgpOn ? Color(hex: 0x2EA82E) : .accentColor)
            .disabled(client.state != .connected)
        }
        .padding(8)
        .background(.bar)
    }
}

struct ChatLine: View {
    let msg: ChatMessage
    let localNick: String
    let remoteNick: String

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateTimeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yy HH:mm:ss"
        return f
    }()

    var body: some View {
        (Text(timeStamp) + encryptionMark + Text(attributed))
            .font(PsiTheme.chatFont)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeStamp: AttributedString {
        let format = Calendar.current.isDateInToday(msg.date) ? Self.timeFormat : Self.dateTimeFormat
        var time = AttributedString("[\(format.string(from: msg.date))] ")
        time.foregroundColor = PsiTheme.timestamp
        time.font = PsiTheme.monoTime
        return time
    }

    /// Картинка, а не символы: текст сообщения не может её изобразить и подделать отметку.
    private var encryptionMark: Text {
        guard msg.encrypted, msg.direction != .system else { return Text(verbatim: "") }
        let verified = msg.verified == true
        let lock = Text(Image(systemName: "lock.fill"))
        let mark = verified ? lock + Text(Image(systemName: "checkmark")) : lock
        return mark.font(.system(size: 11)).foregroundColor(verified ? Color(hex: 0x2EA82E) : .secondary) + Text(verbatim: " ")
    }

    /// Следующие строки с отступом, а символы смены направления убраны: сообщение не должно изображать чужую строку лога.
    private var safeText: String {
        let controls = Set<Unicode.Scalar>((0x202A...0x202E).compactMap(Unicode.Scalar.init)
            + (0x2066...0x2069).compactMap(Unicode.Scalar.init))
        let clean = String(String.UnicodeScalarView(msg.text.unicodeScalars.filter { !controls.contains($0) }))
        return clean.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: "\n    ")
    }

    private var attributed: AttributedString {
        if msg.direction == .system {
            var t = AttributedString("*** \(safeText)")
            t.foregroundColor = PsiTheme.systemText
            return t
        }

        let isMe = msg.direction == .outgoing
        let nickName = isMe ? localNick : (msg.nick ?? remoteNick)

        // /me — как в Psi+: «*ник действие»
        if msg.text.hasPrefix("/me ") {
            var t = AttributedString("*\(nickName) \(safeText.dropFirst(4))")
            t.foregroundColor = isMe ? PsiTheme.nickLocal : PsiTheme.nickRemote
            return t
        }

        var nick = AttributedString("<\(nickName)> ")
        nick.foregroundColor = isMe ? PsiTheme.nickLocal : PsiTheme.nickRemote
        nick.font = PsiTheme.chatFont.bold()

        var body = AttributedString(safeText)
        if msg.decryptFailed { body.foregroundColor = PsiTheme.contactDND }

        return nick + body
    }
}

/// «Назначить ключ OpenPGP» — вставить armored публичный ключ контакта или импортировать файл .asc.
struct AssignKeyView: View {
    let jid: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var client: XMPPClient
    @State private var armored = ""
    @State private var info: String?
    @State private var error: String?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $armored)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 180)
                    Button("Импорт из файла (.asc)…") { importing = true }
                    Button("Вставить из буфера") { armored = UIPasteboard.general.string ?? "" }
                } header: {
                    Text(verbatim: "Публичный ключ \(jid)")
                }
                if let info { Section("Отпечаток") { Text(info).font(.system(.footnote, design: .monospaced)) } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if KeyStore.shared.publicKey(for: jid) != nil {
                    Section {
                        Button("Удалить ключ", role: .destructive) {
                            KeyStore.shared.setPublicKey(nil, for: jid)
                            client.pgpDisabled.remove(jid)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Ключ OpenPGP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save) }
            }
            .onAppear {
                armored = KeyStore.shared.publicKey(for: jid) ?? ""
                updateInfo()
            }
            .onChange(of: armored) { updateInfo() }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.plainText, .data]) { result in
                guard case .success(let url) = result,
                      url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                armored = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
    }

    private func updateInfo() {
        guard !armored.isEmpty else { info = nil; return }
        info = try? PGPService.shared.fingerprint(ofArmored: armored)
    }

    private func save() {
        do {
            _ = try PGPService.shared.fingerprint(ofArmored: armored)
            KeyStore.shared.setPublicKey(armored, for: jid)
            client.pgpDisabled.remove(jid)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
