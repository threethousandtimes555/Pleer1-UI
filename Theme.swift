import SwiftUI
import UIKit

struct Palette {
    var bg: Color
    var ink: Color
    var sub: Color
    var line: Color
    var accent: Color
    var corner: CGFloat
}

enum AppTheme: String, CaseIterable {
    case dark, concrete

    static var current: AppTheme {
        return AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "dark") ?? .dark
    }

    var title: String {
        switch self {
        case .dark: return "Тёмная"
        case .concrete: return "Бетон"
        }
    }

    var scheme: ColorScheme {
        switch self {
        case .dark: return .dark
        case .concrete: return .light
        }
    }

    var palette: Palette {
        switch self {
        case .dark:
            return Palette(bg: Color.black, ink: Color.white, sub: Color.gray,
                           line: Color.white.opacity(0.15),
                           accent: Color(red: 0.91, green: 0.81, blue: 0.42), corner: 0.22)
        case .concrete:
            return Palette(bg: Color(red: 0.93, green: 0.93, blue: 0.92),
                           ink: Color(red: 0.05, green: 0.05, blue: 0.05),
                           sub: Color(red: 0.47, green: 0.47, blue: 0.48),
                           line: Color(red: 0.05, green: 0.05, blue: 0.05),
                           accent: Color(red: 0.05, green: 0.05, blue: 0.05), corner: 0)
        }
    }

    /// Панели UIKit: заголовки и нижнее меню. Для тёмной темы ничего не меняем.
    func applyAppearance() {
        if self != .concrete { return }
        let ink = UIColor(white: 0.05, alpha: 1)
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.largeTitleTextAttributes = [.font: UIFont.systemFont(ofSize: 44, weight: .black), .foregroundColor: ink, .kern: -1.5]
        nav.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: ink]
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(red: 0.93, green: 0.93, blue: 0.92, alpha: 1)
        tab.shadowColor = ink
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

/// Цвет акцента зависит от выбранной темы
var accent: Color { return AppTheme.current.palette.accent }

struct ThemedList: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if AppTheme.current == .concrete {
            content
                .scrollContentBackground(.hidden)
                .background(AppTheme.current.palette.bg)
                .listRowSeparatorTint(Color.black.opacity(0.25))
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
        if AppTheme.current == .concrete {
            content
                .padding(10)
                .background(Rectangle().fill(Color.white))
                .overlay(Rectangle().stroke(Color(red: 0.05, green: 0.05, blue: 0.05), lineWidth: 1))
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
        if AppTheme.current == .concrete {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 28))
                .foregroundColor(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color(red: 0.05, green: 0.05, blue: 0.05)))
        } else {
            Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 66))
        }
    }
}
