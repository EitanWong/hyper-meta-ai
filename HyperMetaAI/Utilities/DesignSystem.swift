/*
 * Design System
 * 统一的设计系统 - 颜色、字体、样式
 */

import SwiftUI

// MARK: - Colors

struct AppColors {
    static let primary = Color(hex: "5B86E5")
    static let secondary = Color(hex: "36D1DC")
    static let accent = Color(hex: "667EEA")

    static let liveAI = Color(hex: "667EEA")
    static let translate = Color(hex: "4ECDC4")
    static let leanEat = Color(hex: "FF6B6B")
    static let wordLearn = Color(hex: "FFA07A")
    static let liveStream = Color(hex: "F38181")
    static let quickVision = Color(hex: "5B86E5")

    static let cardBackground = Color(.systemBackground)
    static let secondaryBackground = Color(.secondarySystemBackground)
    static let tertiaryBackground = Color(.tertiarySystemBackground)

    static let textPrimary = Color(.label)
    static let textSecondary = Color(.secondaryLabel)
    static let textTertiary = Color(.tertiaryLabel)
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Typography

struct AppTypography {
    static let largeTitle = Font.largeTitle.weight(.bold)
    static let title = Font.title.weight(.bold)
    static let title2 = Font.title2.weight(.semibold)
    static let headline = Font.headline
    static let body = Font.body
    static let callout = Font.callout
    static let subheadline = Font.subheadline
    static let footnote = Font.footnote
    static let caption = Font.caption
}

// MARK: - Spacing

struct AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

// MARK: - Corner Radius

struct AppCornerRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
}

// MARK: - Shadows

struct AppShadow {
    static let small = {
        return Color.black.opacity(0.05)
    }

    static let medium = {
        return Color.black.opacity(0.1)
    }

    static let large = {
        return Color.black.opacity(0.15)
    }
}

private struct AssistantSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(tint ?? Color.white.opacity(0.075), in: shape)
            .overlay {
                shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
    }
}

extension View {
    /// A static assistant surface: no blur, material sampling, or continuous rendering.
    func assistantSurface(
        cornerRadius: CGFloat,
        tint: Color? = nil
    ) -> some View {
        modifier(AssistantSurfaceModifier(
            cornerRadius: cornerRadius,
            tint: tint
        ))
    }
}
