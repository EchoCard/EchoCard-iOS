import SwiftUI

struct SettingRow<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let iconColor: Color
    let title: String
    var titleLineLimit: Int? = nil
    var titleMinimumScaleFactor: CGFloat = 1
    var showChevron: Bool = false
    var action: (() -> Void)? = nil
    let content: Content

    init(
        icon: String,
        iconColor: Color,
        title: String,
        titleLineLimit: Int? = nil,
        titleMinimumScaleFactor: CGFloat = 1,
        showChevron: Bool = false,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.titleLineLimit = titleLineLimit
        self.titleMinimumScaleFactor = titleMinimumScaleFactor
        self.showChevron = showChevron
        self.action = action
        self.content = content()
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(iconColor)
                    .cornerRadius(8)

                Text(title)
                    .font(.system(size: 17))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(titleLineLimit)
                    .minimumScaleFactor(titleMinimumScaleFactor)
                    .allowsTightening(true)
                    .layoutPriority(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                content

                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(lightHex: "D1D5DB", darkHex: "4B5563"))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct LanguagePillToggle: View {
    let language: Language
    let setLanguage: (Language) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let segmentWidth: CGFloat = 46
    private let trackPadding: CGFloat = 2
    private var trackWidth: CGFloat { segmentWidth * 2 + trackPadding * 2 }
    private var trackHeight: CGFloat { 30 }
    private var pillHeight: CGFloat { trackHeight - trackPadding * 2 }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color(lightHex: "F2F2F7", darkHex: "2C2C2E"))
                .frame(width: trackWidth, height: trackHeight)

            Capsule()
                .fill(colorScheme == .dark ? Color(hex: "4B5563") : .white)
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                .frame(width: segmentWidth, height: pillHeight)
                .offset(x: language == .zh ? trackPadding : trackPadding + segmentWidth)
                .animation(.easeInOut(duration: 0.2), value: language)

            HStack(spacing: 0) {
                Button { setLanguage(.zh) } label: {
                    Text("中文")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(language == .zh ? Color(hex: "007AFF") : Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                        .frame(width: segmentWidth, height: pillHeight)
                }
                .buttonStyle(.plain)

                Button { setLanguage(.en) } label: {
                    Text("EN")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(language == .en ? Color(hex: "007AFF") : Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                        .frame(width: segmentWidth, height: pillHeight)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, trackPadding)
        }
        .frame(width: trackWidth, height: trackHeight)
    }
}

struct LanguageButton: View {
    let text: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(isSelected ? Color(hex: "007AFF") : Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                .frame(minWidth: 44)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? Color(hex: "007AFF").opacity(0.1) : Color.clear)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}
