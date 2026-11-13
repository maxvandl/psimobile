import SwiftUI

/// Цвета и стиль по умолчанию из Psi+ (options.ui.look.colors.*).
enum PsiTheme {
    // Ростер
    static let contactOnline  = Color(hex: 0x000000)
    static let contactAway    = Color(hex: 0x004BB4)
    static let contactDND     = Color(hex: 0x7E0000)
    static let contactOffline = Color(hex: 0x646464)
    static let groupFore      = Color(hex: 0x5A5A5A)
    static let groupBack      = Color(hex: 0xF0F0F0)
    static let statusText     = Color(hex: 0x808080)
    static let accountBack    = Color(hex: 0x9A9A9A)
    static let barBack        = Color(hex: 0xF4F4F4)
    static let selection      = Color(hex: 0x0B4FD9)

    // Чат
    static let nickLocal  = Color(hex: 0x0000FF)
    static let nickRemote = Color(hex: 0xFF0000)
    static let systemText = Color(hex: 0x008000)
    static let timestamp  = Color(hex: 0x808080)

    static let rosterFont = Font.system(size: 15)
    static let chatFont   = Font.system(size: 15)
    static let monoTime   = Font.system(size: 13, design: .monospaced)

    static func nameColor(_ show: PresenceShow) -> Color {
        switch show {
        case .chat, .online: return contactOnline
        case .away, .xa: return contactAway
        case .dnd: return contactDND
        case .offline: return contactOffline
        }
    }
}

/// Иконка статуса в духе стандартного iconset Psi («лампочки»).
struct StatusIcon: View {
    let show: PresenceShow
    var size: CGFloat = 14

    var body: some View {
        switch show {
        case .chat, .online, .offline:
            // Звезда, как в наборе иконок на ростере Psi+.
            ZStack {
                Image(systemName: "star.fill").resizable().foregroundStyle(starFill)
                Image(systemName: "star").resizable().foregroundStyle(.black.opacity(0.35))
            }
            .frame(width: size, height: size)
        default:
            bulb
        }
    }

    private var starFill: Color {
        show == .offline ? Color(hex: 0x9A9A9A) : Color(hex: 0xF5B301)
    }

    private var bulb: some View {
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.8)
            Circle()
                .fill(.white.opacity(0.55))
                .frame(width: size * 0.38, height: size * 0.38)
                .offset(x: -size * 0.15, y: -size * 0.15)
            overlay
        }
        .frame(width: size, height: size)
    }

    private var fill: Color {
        switch show {
        case .chat:    return Color(hex: 0x3CCB3C)
        case .online:  return Color(hex: 0x2EA82E)
        case .away:    return Color(hex: 0xF2C500)
        case .xa:      return Color(hex: 0xE88A00)
        case .dnd:     return Color(hex: 0xD52B1E)
        case .offline: return Color(hex: 0xB8B8B8)
        }
    }

    @ViewBuilder private var overlay: some View {
        switch show {
        case .dnd:
            Rectangle().fill(.white).frame(width: size * 0.55, height: size * 0.16)
        case .xa:
            Rectangle().fill(.white).frame(width: size * 0.16, height: size * 0.45)
        default:
            EmptyView()
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
