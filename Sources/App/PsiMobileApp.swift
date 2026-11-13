import SwiftUI

/// Токен APNs для XEP-0357 (см. XMPPClient.registerForPush).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        UserDefaults.standard.set(deviceToken.map { String(format: "%02x", $0) }.joined(), forKey: "push.token")
        NotificationCenter.default.post(name: .psiPushToken, object: nil)
    }
}

/// Закрывает экран, пока приложение неактивно: иначе переписка видна в переключателе и попадает в снимок iOS.
/// Отдельное окно, потому что обычный overlay не закрыл бы открытые листы.
@MainActor
enum PrivacyCover {
    private static var window: UIWindow?

    static func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.rootViewController = UIViewController()
        cover.rootViewController?.view.backgroundColor = .white
        cover.isHidden = false
        window = cover
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }
}

@main
struct PsiMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var client = XMPPClient()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("account.jid") private var jid = ""
    @AppStorage("account.host") private var host = ""
    @AppStorage("account.port") private var port = ""

    init() {
        KeyStore.migrateAccessibility()
        KeyStore.migratePin()
        #if DEBUG
        PsiImport.run()
        PsiDemo.prepare()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RosterView()
                .environmentObject(client)
                .preferredColorScheme(.light) // классическая светлая тема Psi+
                .task {
                    KeyStore.clearAfterReinstall()
                    #if DEBUG
                    if PsiDemo.apply(to: client) { return }
                    #endif
                    login()
                    #if DEBUG
                    await PsiImport.reportConnection(client)
                    #endif
                }
                // iOS рвёт соединение в фоне: при возврате на экран снова выходим в сеть.
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        PrivacyCover.hide()
                        HistoryStore.shared.flush()
                        login()
                    } else {
                        PrivacyCover.show()
                    }
                }
        }
    }

    /// Автовход, если аккаунт уже настроен.
    private func login() {
        guard !jid.isEmpty, let pw = Credentials.password, client.isDisconnected else { return }
        client.connect(jid: jid, password: pw, host: host.isEmpty ? nil : host, port: UInt16(port))
    }
}
