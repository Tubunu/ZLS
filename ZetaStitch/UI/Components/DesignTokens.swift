import SwiftUI

public enum ZetaTheme {
    public static let accent = Color.accentColor
    public static let studioCanvas = Color(red: 0.055, green: 0.063, blue: 0.082)
    public static let surfaceCard = Color(uiColor: .secondarySystemGroupedBackground)
    public static let surfaceElevated = Color(uiColor: .tertiarySystemGroupedBackground)
    public static let success = Color(red: 0.133, green: 0.773, blue: 0.369)
    public static let warning = Color(red: 0.961, green: 0.620, blue: 0.043)
    public static let danger = Color(red: 0.937, green: 0.267, blue: 0.267)

    public static let cornerRadiusCard: CGFloat = 18
    public static let cornerRadiusTile: CGFloat = 10
    public static let cornerRadiusPill: CGFloat = 100
}

public struct GlassToolbarModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 8)
    }
}

public extension View {
    func zetaGlassToolbar() -> some View {
        modifier(GlassToolbarModifier())
    }
}
