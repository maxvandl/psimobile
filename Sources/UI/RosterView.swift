import SwiftUI

/// Главное окно Psi+: панель инструментов, свой профиль, аккаунт, группы контактов, внизу кнопка статуса.
struct RosterView: View {
    @EnvironmentObject var client: XMPPClient
    @AppStorage("account.jid") private var jid = ""
    @State private var collapsed: Set<String> = []
    @State private var showOffline = true
    @State private var statusSheet = false
    @State private var settings = false
    @State private var joinSheet = false
    @State private var path: [String] = []
    @State private var selected: String?
    @AppStorage("terms.accepted") private var termsAccepted = false

    private var nick: String { (client.myJID ?? jid).components(separatedBy: "@")[0] }
    private var visibleContacts: [Contact] { client.contacts.values.filter { !client.blocked.contains($0.jid) } }
    private var onlineCount: Int { visibleContacts.filter { $0.show != .offline }.count }
    private var termsPresented: Binding<Bool> {
        Binding(get: { !termsAccepted }, set: { _ in })
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                toolBar
                profile
                ScrollView {
                    LazyVStack(spacing: 0) {
                        accountBar
                        selfRow
                        if !client.conferences.isEmpty {
                            let rooms = client.conferences.values.sorted { $0.jid < $1.jid }
                            groupHeader("Конференции", online: rooms.filter(\.joined).count, total: rooms.count)
                            if !collapsed.contains("Конференции") {
                                ForEach(rooms) { room in
                                    Button {
                                        selected = room.jid
                                        path = [room.jid]
                                    } label: {
                                        ConferenceRow(conference: room, selected: selected == room.jid)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        ForEach(client.groupedContacts, id: \.group) { section in
                            let visible = section.contacts.filter { showOffline || $0.show != .offline }
                            if !visible.isEmpty || showOffline {
                                groupHeader(section.group, online: section.contacts.filter { $0.show != .offline }.count,
                                            total: section.contacts.count)
                                if !collapsed.contains(section.group) {
                                    ForEach(visible) { contact in
                                        Button {
                                            selected = contact.jid
                                            path = [contact.jid]
                                        } label: {
                                            ContactRow(contact: contact, selected: selected == contact.jid)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .background(Color.white)
                }
                .background(Color.white)
                statusButton
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { jid in
                if client.conferences[jid] != nil {
                    ConferenceView(room: jid)
                } else {
                    ChatView(jid: jid)
                }
            }
            .sheet(isPresented: $joinSheet) { JoinConferenceView(defaultNick: nick) }
            .sheet(isPresented: $statusSheet) { StatusSheet() }
            .sheet(isPresented: $settings) { AccountView() }
            .alert("Условия использования", isPresented: termsPresented) {
                Button("Принимаю") { termsAccepted = true }
            } message: {
                Text("Запрещены оскорбления, угрозы, спам и незаконные материалы. Нарушителей можно заблокировать и пожаловаться на них в меню чата; жалобы рассматривает администратор сервера.")
            }
            #if DEBUG
            .onAppear {
                if let chat = PsiDemo.openChat {
                    selected = chat
                    path = [chat]
                }
            }
            #endif
        }
    }

    private var toolBar: some View {
        HStack(spacing: 18) {
            Button { settings = true } label: {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(Color(hex: 0xB07A2A))
            }
            Button { showOffline.toggle() } label: {
                Image(systemName: showOffline ? "person.2.fill" : "person.2").foregroundStyle(Color(hex: 0x3F7D3F))
            }
            Button { joinSheet = true } label: {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Color(hex: 0x2F6FB5))
            }
            Spacer()
        }
        .font(.system(size: 18))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(PsiTheme.barBack)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var profile: some View {
        HStack(spacing: 6) {
            Text("🐧")
                .font(.system(size: 38))
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 3).stroke(Color(hex: 0xA0A0A0)))
            VStack(spacing: 6) {
                Text(nick.isEmpty ? "Psi Mobile" : nick)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 3).stroke(Color(hex: 0xA0A0A0)))
                Button { statusSheet = true } label: {
                    HStack(spacing: 6) {
                        StatusIcon(show: client.myShow, size: 18)
                        Text(client.myStatus)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0xD0D0D0)))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(PsiTheme.barBack)
    }

    private var accountBar: some View {
        HStack(spacing: 5) {
            StatusIcon(show: client.myShow, size: 15)
            Text(client.myJID ?? (jid.isEmpty ? "Нет аккаунта" : jid)).lineLimit(1)
            if KeyStore.shared.ownSecretKey != nil {
                Image(systemName: "lock.fill").foregroundStyle(Color(hex: 0xF5B301))
            }
            Text("(\(onlineCount)/\(visibleContacts.count))")
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(PsiTheme.accountBack)
    }

    private var selfRow: some View {
        HStack(spacing: 8) {
            Text("🐧").font(.system(size: 26)).frame(width: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(nick).font(PsiTheme.rosterFont)
                Text(client.myShow.title).font(.system(size: 12)).foregroundStyle(PsiTheme.statusText)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 42)
    }

    private func groupHeader(_ name: String, online: Int, total: Int) -> some View {
        Button {
            if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed.contains(name) ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 10))
                Text(verbatim: "\(name) (\(online)/\(total))")
                    .font(.system(size: 14))
                Spacer()
            }
            .foregroundStyle(PsiTheme.groupFore)
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(PsiTheme.groupBack)
        }
        .buttonStyle(.plain)
    }

    private var statusButton: some View {
        Button { statusSheet = true } label: {
            HStack(spacing: 8) {
                Spacer()
                StatusIcon(show: client.myShow, size: 18)
                Text(statusLabel).lineLimit(1).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(hex: 0xD8D8D8))
        }
        .buttonStyle(.plain)
    }

    private var statusLabel: String {
        switch client.state {
        case .connecting: return "Подключение…"
        case .disconnected: return "Нет соединения"
        case .error(let e): return "Ошибка: \(e)"
        case .connected: return client.myShow.title
        }
    }
}

struct ConferenceRow: View {
    let conference: Conference
    let selected: Bool

    private var statusLine: String {
        if let error = conference.error { return error }
        return conference.joined ? "Участников: \(conference.occupants.count)" : "Не подключено"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 18))
                .foregroundStyle(selected ? Color.white : (conference.joined ? Color(hex: 0x6F8FC9) : Color(hex: 0xA8A8A8)))
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(conference.name)
                    .font(PsiTheme.rosterFont)
                    .foregroundStyle(selected ? Color.white : PsiTheme.contactOnline)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.white : (conference.error == nil ? PsiTheme.statusText : PsiTheme.contactDND))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(selected ? PsiTheme.selection : Color.white)
        .contentShape(Rectangle())
    }
}

struct ContactRow: View {
    let contact: Contact
    let selected: Bool

    private var nameColor: Color {
        if selected { return .white }
        return contact.show == .offline ? PsiTheme.contactOnline : PsiTheme.nameColor(contact.show)
    }

    private var statusLine: String {
        if let s = contact.status, !s.isEmpty { return s }
        return contact.show.title
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "person.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(contact.show == .offline ? Color(hex: 0xA8A8A8) : Color(hex: 0x6F8FC9))
                    .frame(width: 34, height: 34)
                StatusIcon(show: contact.show, size: 15)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.displayName)
                    .font(PsiTheme.rosterFont)
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? .white : PsiTheme.statusText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if contact.signatureValid {
                Image(systemName: "key.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? .white : Color(hex: 0xB8860B))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(selected ? PsiTheme.selection : Color.white)
        .contentShape(Rectangle())
    }
}

struct StatusSheet: View {
    @EnvironmentObject var client: XMPPClient
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Текст статуса") {
                    TextField("Статус", text: $text, axis: .vertical)
                }
            }
            .navigationTitle("Статус")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        client.setStatus(text: text)
                        dismiss()
                    }
                }
            }
            .onAppear { text = client.myStatus }
        }
        .presentationDetents([.medium, .large])
    }
}
