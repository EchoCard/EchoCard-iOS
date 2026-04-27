//
//  DesignSystem.swift
//  CallMate
//
//  Unified design system for premium iOS experience.
//  与 newui/design-system/DesignSystem.tsx（iOS 标准设计规范库）对齐：颜色、字号、间距、圆角、阴影。

import SwiftUI

// MARK: - Color Palette (完全采用 newui iOS 标准设计规范，支持浅/深色自适应)
struct AppColors {
    // 品牌与功能色 — newui Color/Brand/Primary, Status/Success|Warning|Danger
    static let primary = Color(lightHex: "007AFF", darkHex: "0A84FF")
    static let primaryLight = Color(lightHex: "007AFF", darkHex: "0A84FF").opacity(0.1) // newui 次级按钮/选中高亮约 10%
    static let success = Color(lightHex: "34C759", darkHex: "30D158")
    static let warning = Color(lightHex: "FF9500", darkHex: "FF9F0A")
    static let error = Color(lightHex: "FF3B30", darkHex: "FF453A")
    
    // Accent — 紫色强调（实习期、进度等）
    static let accent = Color(lightHex: "5856D6", darkHex: "5E5CE6")
    static let accentLight = Color(hex: "5856D6").opacity(0.1)
    
    // 文字 — newui Text/Primary, Secondary 60%, Tertiary 30%
    static let textPrimary = Color(lightHex: "000000", darkHex: "FFFFFF")
    static let textSecondary = Color(lightHex: "3C3C43", darkHex: "EBEBF5").opacity(0.6)
    static let textTertiary = Color(lightHex: "3C3C43", darkHex: "EBEBF5").opacity(0.3)
    
    // 背景 — newui Bg/System Primary(页面底层)、Secondary(卡片)、Tertiary(嵌套)
    static let backgroundPage = Color(lightHex: "F2F2F7", darkHex: "000000")
    static let backgroundCard = Color(lightHex: "FFFFFF", darkHex: "1C1C1E")
    static let backgroundCardTertiary = Color(lightHex: "FFFFFF", darkHex: "2C2C2E")
    
    // 兼容旧用法：background = 卡片，backgroundSecondary = 页面底，backgroundTertiary = 卡片内嵌套
    static let background = backgroundCard
    static let backgroundSecondary = backgroundPage
    static let backgroundTertiary = backgroundCardTertiary
    
    // 分割线/边框 — newui Border/Divider 18%
    static let separator = Color(lightHex: "3C3C43", darkHex: "545458").opacity(0.18)
    static let border = Color(lightHex: "3C3C43", darkHex: "545458").opacity(0.18)
    
    // 列表/控件 — newui 分段控制器等底层：F2F2F7 / 2C2C2E
    static let backgroundGrouped = Color(lightHex: "F2F2F7", darkHex: "2C2C2E")
    /// 设置行 chevron 等弱化图标
    static let chevron = Color(lightHex: "D1D5DB", darkHex: "636366")
    
    // Surfaces（与卡片一致，便于 cardStyle 等）
    static let surface = Color(lightHex: "FFFFFF", darkHex: "1C1C1E")
    static let surfaceElevated = Color(lightHex: "F9F9F9", darkHex: "2C2C2E")
}

// MARK: - Typography (与 newui 一致: LargeTitle 34 Bold, Title1/2 28/22 Medium, Headline 17 Semibold, Body 17 Regular, Subhead 15, Footnote 13, Caption1 12)
struct AppTypography {
    // Large Title — 34pt Bold
    static let largeTitle = Font.system(size: 34, weight: .bold, design: .rounded)
    
    // Titles — newui Title1 28 Medium, Title2 22 Medium
    static let title1 = Font.system(size: 28, weight: .medium, design: .rounded)
    static let title2 = Font.system(size: 22, weight: .medium, design: .rounded)
    static let title3 = Font.system(size: 20, weight: .semibold, design: .rounded)
    
    // Body
    static let body = Font.system(size: 17, weight: .regular)
    static let bodyEmphasized = Font.system(size: 17, weight: .semibold)
    
    // Callout
    static let callout = Font.system(size: 16, weight: .regular)
    static let calloutEmphasized = Font.system(size: 16, weight: .semibold)
    
    // Subheadline
    static let subheadline = Font.system(size: 15, weight: .regular)
    static let subheadlineEmphasized = Font.system(size: 15, weight: .semibold)
    
    // Footnote
    static let footnote = Font.system(size: 13, weight: .regular)
    static let footnoteEmphasized = Font.system(size: 13, weight: .semibold)
    
    // Caption
    static let caption1 = Font.system(size: 12, weight: .regular)
    static let caption2 = Font.system(size: 11, weight: .regular)
}

// MARK: - Spacing (与 newui: 屏幕边距 16/20pt, 区块 24/32pt, 组件内 8/12pt，4pt 栅格)
struct AppSpacing {
    static let xxxs: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40
}

// MARK: - Corner Radius (与 newui: Small 8pt, Medium 12pt, Large 16pt, XLarge 20pt)
struct AppRadius {
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 32
    static let full: CGFloat = 999
}

// MARK: - Shadows (与 newui: Light y:2 blur:8 4%, Medium y:8 blur:24 8%, Heavy y:16 blur:40 12%)
struct AppShadow {
    static let sm = Shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    static let md = Shadow(color: .black.opacity(0.08), radius: 24, y: 8)
    static let lg = Shadow(color: .black.opacity(0.12), radius: 40, y: 16)
}

struct Shadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
    
    init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

// MARK: - Animations
struct AppAnimations {
    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.75)
    static let easeOut = Animation.easeOut(duration: 0.3)
    static let easeInOut = Animation.easeInOut(duration: 0.25)
}

// MARK: - Strict Tokens for AI-generated UI（与 newui 规范一致）
enum DS {
    enum ColorToken {
        static let primary = Color(lightHex: "007AFF", darkHex: "0A84FF")
        static let accent = Color(lightHex: "5856D6", darkHex: "5E5CE6")
        static let background = Color(lightHex: "F2F2F7", darkHex: "000000")
        static let card = Color(lightHex: "FFFFFF", darkHex: "1C1C1E")
        static let text = Color(lightHex: "000000", darkHex: "FFFFFF")
        static let subtext = Color(lightHex: "3C3C43", darkHex: "EBEBF5").opacity(0.6)
        static let border = Color(lightHex: "3C3C43", darkHex: "545458").opacity(0.18)
    }

    enum Spacing {
        static let x1: CGFloat = 8
        static let x2: CGFloat = 16
        static let x3: CGFloat = 24
        static let x4: CGFloat = 32
        static let x6: CGFloat = 48
    }

    enum Radius {
        static let button: CGFloat = 12
        static let card: CGFloat = 20
    }

    enum Typography {
        // Dynamic Type friendly text styles with fixed hierarchy.
        static let title = Font.system(.title2, design: .default).weight(.semibold)
        static let body = Font.system(.body, design: .default)
        static let caption = Font.system(.caption, design: .default)
    }

    enum Shadow {
        static let card = AppShadow.sm
    }
}

// MARK: - Color Extension for Hex
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
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

// MARK: - Dynamic Color Helper
extension Color {
    init(lightHex: String, darkHex: String) {
#if canImport(UIKit)
        self.init(
            uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(Color(hex: darkHex))
                    : UIColor(Color(hex: lightHex))
            }
        )
#else
        self.init(hex: lightHex)
#endif
    }
}

// MARK: - View Modifiers
extension View {
    func appShadow(_ shadow: Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
    
    func cardStyle() -> some View {
        self
            .background(AppColors.surface)
            .cornerRadius(AppRadius.lg)
            .appShadow(AppShadow.sm)
    }
    
    func primaryButtonStyle() -> some View {
        self
            .font(AppTypography.bodyEmphasized)
            .foregroundColor(.white)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .background(AppColors.primary)
            .cornerRadius(AppRadius.full)
    }
    
    func secondaryButtonStyle() -> some View {
        self
            .font(AppTypography.bodyEmphasized)
            .foregroundColor(AppColors.primary)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .background(AppColors.primaryLight)
            .cornerRadius(AppRadius.full)
    }

    // DS style wrappers for AI-generated pages.
    func dsCardStyle() -> some View {
        self
            .background(DS.ColorToken.card)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .stroke(DS.ColorToken.border, lineWidth: 1)
            )
            .cornerRadius(DS.Radius.card)
            .appShadow(DS.Shadow.card)
    }

    func dsPrimaryButtonStyle() -> some View {
        self
            .font(DS.Typography.body.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, DS.Spacing.x2)
            .padding(.vertical, DS.Spacing.x2)
            .background(DS.ColorToken.primary)
            .cornerRadius(DS.Radius.button)
            .appShadow(Shadow(color: .black.opacity(0.08), radius: 8, y: 4))
    }
}
