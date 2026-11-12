import SwiftUI

extension Color {
    /// "#rrggbb" to a colour.
    init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count != 6 { h = "ff6a3d" }
        let n = UInt32(h, radix: 16) ?? 0xff6a3d
        self.init(red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
    }
    /// A colour back to "#rrggbb".
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

private func adaptive(dark: UIColor, light: UIColor) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
}

/// Colours from the web app. Backgrounds and text follow the theme (Settings → Appearance); the accent follows the chosen colour.
enum Theme {
    static let bg = adaptive(dark: UIColor(red: 12 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1),
                             light: UIColor(red: 244 / 255, green: 241 / 255, blue: 236 / 255, alpha: 1))
    static let surface = adaptive(dark: UIColor(red: 29 / 255, green: 29 / 255, blue: 35 / 255, alpha: 1),
                                  light: UIColor.white)
    static let muted = adaptive(dark: UIColor(white: 1, alpha: 0.6), light: UIColor(white: 0, alpha: 0.55))
    /// The tint set at the top of the app, so a change in Settings shows straight away.
    static var accent: Color { Color.accentColor }
}

let accentChoices: [(name: String, hex: String)] = [
    ("Coral", "#ff6a3d"), ("Periwinkle", "#7c8cff"), ("Mint", "#2dd4a7"), ("Amber", "#f5c542"),
    ("Rose", "#ff5c8a"), ("Sky", "#4cc3ff"), ("Violet", "#a78bfa"), ("Lime", "#a3e635"),
]

/// "1 song" or "5 songs".
func songsLabel(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
}
