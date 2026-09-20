import SwiftUI
import UIKit

// MARK: - Colours

/// Semble's palette, as used on semble.so. The orange reads well on both
/// light and dark backgrounds so it is used as-is in both appearances; the
/// surface and text colours adapt.
extension Color {
    /// Semble's brand orange (#FF6400).
    static let sembleOrange = Color(hex: 0xFF6400)
    /// The pressed-state orange (#E45800).
    static let sembleOrangeDark = Color(hex: 0xE45800)
    /// The warm cream Semble uses for cards and highlights (#FFF1E2).
    static let sembleCream = Color(hex: 0xFFF1E2)
    /// Near-black ink for headline text (#1C1917).
    static let sembleInk = Color(hex: 0x1C1917)

    static let sembleStone100 = Color(hex: 0xF5F5F4)
    static let sembleStone200 = Color(hex: 0xE7E5E4)
    static let sembleStone300 = Color(hex: 0xD6D3D1)
    static let sembleStone500 = Color(hex: 0x78716C)
    static let sembleStone700 = Color(hex: 0x44403C)
    static let sembleStone800 = Color(hex: 0x292524)

    /// Page background: system background in both appearances.
    static let sembleBackground = Color(uiColor: .systemBackground)

    /// A raised card surface: cream in light mode, warm stone in dark mode.
    static let sembleSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x292524) : UIColor(hex: 0xFFF1E2)
    })

    /// A quiet field background: light stone in light mode, dark stone in dark mode.
    static let sembleField = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x1C1917) : UIColor(hex: 0xF5F5F4)
    })

    /// Hairlines and borders.
    static let sembleBorder = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x44403C) : UIColor(hex: 0xE7E5E4)
    })

    /// Primary text: ink in light mode, near-white in dark mode.
    static let sembleText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0xFAFAF9) : UIColor(hex: 0x1C1917)
    })

    /// Secondary text.
    static let sembleMutedText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0xA8A29E) : UIColor(hex: 0x78716C)
    })

    /// Builds an opaque sRGB colour from a `0xRRGGBB` literal.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension UIColor {
    /// Builds an opaque sRGB colour from a `0xRRGGBB` literal.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Button style

/// Semble's primary call to action: a filled orange capsule with bold white
/// text. Dims to the darker orange while pressed and fades when disabled.
struct SembleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(configuration.isPressed ? Color.sembleOrangeDark : Color.sembleOrange)
            .clipShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SembleButtonStyle {
    /// `.buttonStyle(.semble)`
    static var semble: SembleButtonStyle { SembleButtonStyle() }
}

// MARK: - Small shared pieces

/// A wordmark-ish title used at the top of both the app and the share sheet.
struct SembleTitle: View {
    var text: String = "Add to Semble"

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.sembleOrange)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(text)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.sembleText)
        }
    }
}
