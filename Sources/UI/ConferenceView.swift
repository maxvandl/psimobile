import SwiftUI

/// Окно конференции: лог как в чате, без шифрования, со списком участников.
struct ConferenceView: View {
    let room: String
    @EnvironmentObject var client: XMPPClient
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var occupantsSheet = false
    @State private var confirmLeave = false

    private var conference: Conference? { client.conferences[room] }
    private var log: [ChatMessage] { client.messages[room] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log) { msg in
                            ChatLine(msg: msg, localNick: conference?.nick ?? "Я", remoteNick: room)
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
        .onAppear { client.loadHistory(room) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(conference?.name ?? room).font(.headline).lineLimit(1)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Участники (\(conference?.occupants.count ?? 0))") { occupantsSheet = true }
                    Button("Покинуть", role: .destructive) { confirmLeave = true }
                } label: {
                    Image(systemName: "person.2.fill")
                }
            }
        }
        .sheet(isPresented: $occupantsSheet) { OccupantsView(room: room) }
        .confirmationDialog("Покинуть конференцию? История останется на устройстве.",
                            isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Покинуть", role: .destructive) {
                client.leave(room: room)
                dismiss()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.open").font(.system(size: 12)).foregroundStyle(PsiTheme.contactDND)
            Text("Без шифрования, сообщения видны серверу").font(.system(size: 12))
            Spacer()
            if let error = conference?.error {
                Text(error).font(.system(size: 12)).foregroundStyle(PsiTheme.contactDND).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(PsiTheme.groupBack)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Сообщение", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: 0xA0A0A0)))
            Button {
                let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                client.sendToRoom(text, room: room)
                input = ""
            } label: {
                Text("Отпр.").bold()
            }
            .buttonStyle(.borderedProminent)
            .disabled(conference?.joined != true)
        }
        .padding(8)
        .background(.bar)
    }
}

/// Участники конференции; игнорирование и жалоба — через обычную блокировку room/nick.
struct OccupantsView: View {
    let room: String
    @EnvironmentObject var client: XMPPClient
    @Environment(\.dismiss) private var dismiss

    private var occupants: [(nick: String, show: PresenceShow)] {
        (client.conferences[room]?.occupants ?? [:])
            .map { (nick: $0.key, show: $0.value) }
            .sorted { $0.nick.localizedCaseInsensitiveCompare($1.nick) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(occupants, id: \.nick) { occupant in
                HStack {
                    StatusIcon(show: occupant.show)
                    Text(occupant.nick).lineLimit(1)
                    Spacer()
                    if occupant.nick != client.conferences[room]?.nick {
                        menu(for: client.conferences[room]?.occupantJIDs[occupant.nick] ?? "\(room)/\(occupant.nick)")
                    }
                }
            }
            .navigationTitle("Участники")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }

    @ViewBuilder private func menu(for jid: String) -> some View {
        if client.blocked.contains(jid) {
            Button("Вернуть") { client.unblock(jid) }.buttonStyle(.borderless)
        } else {
            Menu {
                Button("Игнорировать", role: .destructive) { client.block(jid) }
                ForEach(ReportReason.allCases) { reason in
                    Button("Пожаловаться: \(reason.title)", role: .destructive) { client.block(jid, report: reason) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

/// Вход в конференцию по адресу комнаты и нику.
struct JoinConferenceView: View {
    @EnvironmentObject var client: XMPPClient
    @Environment(\.dismiss) private var dismiss
    let defaultNick: String
    @State private var room = ""
    @State private var nick = ""

    private var example: String {
        let domain = client.myJID?.components(separatedBy: "@").last ?? "example.org"
        return "room@conference.\(domain)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Адрес комнаты", text: $room)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                    TextField("Ник", text: $nick)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Например: \(example). Участники увидят ваш ник и вход в комнату. Комнаты с паролем пока не поддерживаются.")
                }
            }
            .navigationTitle("Конференция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Войти") {
                        client.join(room: room, nick: nick)
                        dismiss()
                    }
                    .disabled(!room.contains("@") || nick.isEmpty)
                }
            }
            .onAppear { nick = defaultNick }
        }
    }
}
