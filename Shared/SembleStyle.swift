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

    /// Semble's blue, for the link/domain line. The web uses blue-6
    /// (#23AFED) in both schemes, but on the light cream card that is only
    /// about 2.5:1 against the background. Light mode therefore uses blue-9
    /// from the same ramp, which clears WCAG AA for small text; dark mode
    /// keeps blue-6, which is already well clear against the dark surface.
    static let sembleLink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x23AFED) : UIColor(hex: 0x0076A8)
    })

    /// The two ends of the header wash. Sampled from the banner Semble uses
    /// in its browser extension: pale sky to mint in light mode, deep navy
    /// in dark.
    static let sembleWashStart = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x000A2B) : UIColor(hex: 0xD6EFF8)
    })

    static let sembleWashEnd = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x00113E) : UIColor(hex: 0x83C8A2)
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

/// Semble's mark: four stacked stones. Transcribed from the SVG published
/// in Semble's browser extension (MIT, © 2025 Homeworld Collective Inc.) so
/// it scales and tints as a shape, rather than bundling an image the share
/// extension would have to decode. See Design/README.md.
struct SembleMark: Shape {
    /// The artwork's 32 × 43 bounding box, as width ÷ height.
    static let aspectRatio: CGFloat = 32.0 / 43.0

    func path(in rect: CGRect) -> Path {
        // Fit the artwork's box inside `rect` without distorting it.
        let scale = min(rect.width / 32, rect.height / 43)
        let originX = rect.midX - 32 * scale / 2
        let originY = rect.midY - 43 * scale / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        // Blob 1
        path.move(to: p(31.0164, 33.1306))
        path.addCurve(to: p(15.8607, 42.9994), control1: p(31.0164, 38.581), control2: p(25.7882, 42.9994))
        path.addCurve(to: p(0, 32.0732), control1: p(5.93311, 42.9994), control2: p(0, 37.5236))
        path.addCurve(to: p(15.8607, 23.2617), control1: p(0, 26.6228), control2: p(5.93311, 23.2617))
        path.addCurve(to: p(31.0164, 33.1306), control1: p(25.7882, 23.2617), control2: p(31.0164, 27.6802))
        path.closeSubpath()
        // Blob 2
        path.move(to: p(25.7295, 19.3862))
        path.addCurve(to: p(15.1558, 22.2058), control1: p(25.7295, 22.5007), control2: p(20.7964, 22.2058))
        path.addCurve(to: p(4.93445, 19.0337), control1: p(9.51511, 22.2058), control2: p(4.93445, 22.1482))
        path.addCurve(to: p(15.356, 12.6895), control1: p(4.93445, 15.9192), control2: p(9.71537, 12.6895))
        path.addCurve(to: p(25.7295, 19.3862), control1: p(20.9967, 12.6895), control2: p(25.7295, 16.2717))
        path.closeSubpath()
        // Blob 3
        path.move(to: p(25.0246, 10.9256))
        path.addCurve(to: p(15.1557, 11.9829), control1: p(25.0246, 14.0401), control2: p(20.7964, 11.9829))
        path.addCurve(to: p(6.34424, 10.5731), control1: p(9.51506, 11.9829), control2: p(6.34424, 13.6876))
        path.addCurve(to: p(15.1557, 5.63867), control1: p(6.34424, 7.45857), control2: p(9.51506, 5.63867))
        path.addCurve(to: p(25.0246, 10.9256), control1: p(20.7964, 5.63867), control2: p(25.0246, 7.81103))
        path.closeSubpath()
        // Blob 4
        path.move(to: p(20.4426, 3.5755))
        path.addCurve(to: p(15.2288, 4.22951), control1: p(20.4426, 5.8323), control2: p(18.2088, 4.22951))
        path.addCurve(to: p(10.5737, 3.5755), control1: p(12.2489, 4.22951), control2: p(10.5737, 5.8323))
        path.addCurve(to: p(15.2288, 0), control1: p(10.5737, 1.31871), control2: p(12.2489, 0))
        path.addCurve(to: p(20.4426, 3.5755), control1: p(18.2088, 0), control2: p(20.4426, 1.31871))
        path.closeSubpath()
        return path
    }
}

/// The soft wash Semble puts behind the header of its browser extension: a
/// pale sky-to-mint gradient in light mode, deep navy in dark, fading out
/// before it reaches the content.
///
/// Drawn rather than shipped: Semble's own asset is a 5079 × 1049 image,
/// which is far more than a share extension's memory budget can spare for
/// decoration.
struct SembleHeaderWash: View {
    /// The height of the banner in Semble's own popup.
    var height: CGFloat = 76

    var body: some View {
        LinearGradient(
            colors: [.sembleWashStart, .sembleWashEnd],
            startPoint: .leading,
            endPoint: .trailing
        )
        .opacity(0.5)
        .frame(height: height)
        // Solid for the top 45%, then out to nothing, as Semble's mask does.
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.45),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The mark and title used at the top of both the app and the share sheet.
struct SembleTitle: View {
    var text: String = "Add to Semble"

    /// Grows with the user's text size, so the mark never looks stranded
    /// next to a large title.
    @ScaledMetric(relativeTo: .title2) private var markHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: 10) {
            SembleMark()
                .fill(Color.sembleOrange)
                .frame(width: markHeight * SembleMark.aspectRatio, height: markHeight)
                .accessibilityHidden(true)
            Text(text)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.sembleText)
        }
    }
}
