import SwiftUI
import UIKit

// MARK: - 主题色板（对标安卓 Design.kt）

/// 4 个强调色（对标安卓 accents：Ember / 蓝 / 松绿 / 紫）
public let GO_PAN_ACCENTS: [Color] = [
    Color(hex: 0xD95D39),
    Color(hex: 0x3675A9),
    Color(hex: 0x527F65),
    Color(hex: 0x8065AA),
]

public extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    /// 与另一色插值（对标安卓 lerp，用于 primaryContainer）
    func lerp(to other: Color, fraction: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(red: Double(r1 + (r2 - r1) * fraction),
                     green: Double(g1 + (g2 - g1) * fraction),
                     blue: Double(b1 + (b2 - b1) * fraction))
    }

    func brighten(_ amount: Double) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: min(1, Double(r) + amount), green: min(1, Double(g) + amount), blue: min(1, Double(b) + amount))
    }

    /// tint @10% 透明度背景（文件图标盒）
    var faint: Color { opacity(0.10) }
}

/// 一套完整色板：按强调色 + 明暗模式计算（对标安卓 Design.kt 色值表）
public struct Palette {
    public let accent: Color
    public let background: Color
    public let surface: Color
    public let surfaceContainer: Color
    public let surfaceContainerLow: Color
    public let surfaceContainerHighest: Color
    public let outline: Color
    public let onSurface: Color
    public let onSurfaceVariant: Color
    public let outlineVariant: Color
    public let primary: Color
    public let onPrimary: Color
    public let primaryContainer: Color
    public let onPrimaryContainer: Color
    public let error: Color
    public let errorContainer: Color
    public let onErrorContainer: Color
    public let success: Color

    public static func make(accentIndex: Int, dark: Bool) -> Palette {
        let accent = GO_PAN_ACCENTS[max(0, min(GO_PAN_ACCENTS.count - 1, accentIndex))]
        if dark {
            return Palette(
                accent: accent,
                background: Color(hex: 0x141916),
                surface: Color(hex: 0x1E2521),
                surfaceContainer: Color(hex: 0x252D27),
                surfaceContainerLow: Color(hex: 0x1C231F),
                surfaceContainerHighest: Color(hex: 0x303B33),
                outline: Color(hex: 0x7B877E),
                onSurface: Color(hex: 0xE9EEE7),
                onSurfaceVariant: Color(hex: 0x9EA99F),
                outlineVariant: Color(hex: 0x374139),
                primary: accent.brighten(0.2),
                onPrimary: .white,
                primaryContainer: accent.lerp(to: Color(hex: 0x1E2521), fraction: 0.65),
                onPrimaryContainer: .white,
                error: Color(hex: 0xFFB4AB),
                errorContainer: Color(hex: 0x5C1A14),
                onErrorContainer: Color(hex: 0xFFDAD4),
                success: Color(hex: 0x699879)
            )
        }
        return Palette(
            accent: accent,
            background: Color(hex: 0xF7F8F5),
            surface: .white,
            surfaceContainer: Color(hex: 0xF0F3EC),
            surfaceContainerLow: Color(hex: 0xFAFBF8),
            surfaceContainerHighest: Color(hex: 0xE8EDE5),
            outline: Color(hex: 0x7B877E),
            onSurface: Color(hex: 0x23302A),
            onSurfaceVariant: Color(hex: 0x7B877E),
            outlineVariant: Color(hex: 0xE3E9DF),
            primary: accent,
            onPrimary: .white,
            primaryContainer: accent.lerp(to: .white, fraction: 0.88),
            onPrimaryContainer: accent,
            error: Color(hex: 0xB3261E),
            errorContainer: Color(hex: 0xF9DEDC),
            onErrorContainer: Color(hex: 0x410E0B),
            success: Color(hex: 0x699879)
        )
    }
}

// MARK: - 环境注入

private struct GThemeKey: EnvironmentKey {
    static let defaultValue: Palette = .make(accentIndex: 0, dark: false)
}

public extension EnvironmentValues {
    var gTheme: Palette {
        get { self[GThemeKey.self] }
        set { self[GThemeKey.self] = newValue }
    }
}

// MARK: - 字号规格（对标安卓字体规格）

public extension Font {
    /// headlineLarge 32sp Bold
    static var gHeadlineLarge: Font { .system(size: 30, weight: .bold) }
    /// headlineMedium 26sp SemiBold
    static var gHeadlineMedium: Font { .system(size: 25, weight: .semibold) }
    /// titleLarge 21sp SemiBold
    static var gTitleLarge: Font { .system(size: 20, weight: .semibold) }
    /// titleMedium 16sp SemiBold
    static var gTitleMedium: Font { .system(size: 16, weight: .semibold) }
    /// titleSmall 14sp SemiBold（安卓 TransferCard 等使用）
    static var gTitleSmall: Font { .system(size: 14, weight: .semibold) }
    /// bodyLarge 15sp
    static var gBodyLarge: Font { .system(size: 15) }
    /// bodyMedium 13sp
    static var gBodyMedium: Font { .system(size: 13) }
    /// bodySmall 12sp
    static var gBodySmall: Font { .system(size: 12) }
    /// labelSmall 11sp Medium
    static var gLabelSmall: Font { .system(size: 11, weight: .medium) }
    /// labelMedium 12sp Medium
    static var gLabelMedium: Font { .system(size: 12, weight: .medium) }
}
