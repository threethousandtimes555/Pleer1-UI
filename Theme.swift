import SwiftUI
import UIKit

struct Palette {
    var bg: Color
    var ink: Color
    var sub: Color
    var accent: Color
    var fill: Color
    var corner: CGFloat
}

enum AppTheme: String, CaseIterable {
    case dark, soft

    static var current: AppTheme {
        return AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "soft") ?? .soft
    }

    var title: String {
        switch self {
        case .dark: return "Тёмная"
        case .soft: return "Светлая"
        }
    }

    var scheme: ColorScheme {
        switch self {
        case .dark: return .dark
        case .soft: return .light
        }
    }

    var palette: Palette {
        switch self {
        case .dark:
            return Palette(bg: Color.black, ink: Color.white, sub: Color.gray,
                           accent: Color(red: 0.91, green: 0.81, blue: 0.42),
                           fill: Color(red: 0.91, green: 0.81, blue: 0.42), corner: 0.22)
        case .soft:
            return Palette(bg: Color(red: 0.957, green: 0.953, blue: 0.937),
                           ink: Color(red: 0.12, green: 0.12, blue: 0.11),
                           sub: Color(red: 0.48, green: 0.48, blue: 0.45),
                           accent: Color(red: 0.54, green: 0.54, blue: 0.49),
                           fill: Color(red: 0.76, green: 0.76, blue: 0.72), corner: 0.26)
        }
    }

    /// Заголовки экранов: крупный округлый шрифт. Для тёмной темы ничего не меняем.
    func applyAppearance() {
        if self != .soft { return }
        let base = UIFont.systemFont(ofSize: 36, weight: .bold)
        let font: UIFont
        if let d = base.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: d, size: 36)
        } else {
            font = base
        }
        let ink = UIColor(red: 0.12, green: 0.12, blue: 0.11, alpha: 1)
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.largeTitleTextAttributes = [.font: font, .foregroundColor: ink]
        nav.titleTextAttributes = [.foregroundColor: ink]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}

/// Цвет акцента зависит от выбранной темы
var accent: Color { return AppTheme.current.palette.accent }

struct ThemedList: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if AppTheme.current == .soft {
            content
                .scrollContentBackground(.hidden)
                .background(
                    LinearGradient(colors: [Color(red: 0.965, green: 0.961, blue: 0.945), Color(red: 0.90, green: 0.895, blue: 0.87)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .listRowSeparatorTint(Color.black.opacity(0.08))
        } else {
            content
        }
    }
}

extension View {
    func themedList() -> some View { return modifier(ThemedList()) }
}

struct MiniStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if AppTheme.current == .soft {
            content
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 26).fill(Color.white))
                .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 6)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        } else {
            content
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
    }
}

struct PlayGlyph: View {
    let playing: Bool

    var body: some View {
        if AppTheme.current == .soft {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 28))
                .foregroundColor(AppTheme.soft.palette.ink)
                .frame(width: 76, height: 76)
                .background(Circle().fill(AppTheme.soft.palette.fill))
        } else {
            Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 66))
        }
    }
}
