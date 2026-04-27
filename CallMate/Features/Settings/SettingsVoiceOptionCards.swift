import SwiftUI

struct VoiceToneOptionCard: View {
    let language: Language
    let tone: VoiceTone
    let isSelected: Bool
    let isPlaying: Bool
    let onSelect: () -> Void
    let onPlayToggle: () -> Void

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        HStack(spacing: DS.Spacing.x2) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tone.displayName(language: language))
                    .font(DS.Typography.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(isSelected ? AppColors.primary : AppColors.textPrimary)
                if isSelected {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text(t("当前使用", "Active"))
                            .font(DS.Typography.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(AppColors.primary)
                }
            }

            Spacer(minLength: 0)

            Button {
                onPlayToggle()
            } label: {
                Group {
                    if isPlaying {
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 1).frame(width: 2, height: 10)
                            RoundedRectangle(cornerRadius: 1).frame(width: 2, height: 6)
                            RoundedRectangle(cornerRadius: 1).frame(width: 2, height: 8)
                        }
                        .foregroundStyle(.white)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(isSelected ? AppColors.primary : AppColors.textSecondary)
                            .padding(.leading, 1)
                    }
                }
                .frame(width: 32, height: 32)
                .background(
                    Group {
                        if isPlaying {
                            AppColors.primary
                        } else if isSelected {
                            AppColors.background
                        } else {
                            AppColors.backgroundSecondary
                        }
                    }
                )
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(DS.Spacing.x2)
        .background(isSelected ? AppColors.primary.opacity(0.08) : AppColors.background)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.button)
                .stroke(isSelected ? AppColors.primary.opacity(0.2) : Color.clear, lineWidth: 2)
        )
        .overlay(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onSelect() }
                .padding(.trailing, 44)
        )
    }
}

struct TTSVoiceOptionCard: View {
    let language: Language
    let voice: TTSVoice
    let isSelected: Bool
    let isPlaying: Bool
    let onSelect: () -> Void
    let onPlayToggle: () -> Void

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        HStack(spacing: DS.Spacing.x2) {
            VStack(alignment: .leading, spacing: 4) {
                Text(voice.name)
                    .font(DS.Typography.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(isSelected ? AppColors.primary : AppColors.textPrimary)
                if isSelected {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text(t("当前使用", "Active"))
                            .font(DS.Typography.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(AppColors.primary)
                }
            }

            Spacer(minLength: 0)

            Button {
                onPlayToggle()
            } label: {
                Group {
                    if isPlaying {
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 1).frame(width: 2, height: 10)
                            RoundedRectangle(cornerRadius: 1).frame(width: 2, height: 6)
                            RoundedRectangle(cornerRadius: 1).frame(width: 2, height: 8)
                        }
                        .foregroundStyle(.white)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(isSelected ? AppColors.primary : AppColors.textSecondary)
                            .padding(.leading, 1)
                    }
                }
                .frame(width: 32, height: 32)
                .background(
                    Group {
                        if isPlaying {
                            AppColors.primary
                        } else if isSelected {
                            AppColors.background
                        } else {
                            AppColors.backgroundSecondary
                        }
                    }
                )
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(DS.Spacing.x2)
        .background(isSelected ? AppColors.primary.opacity(0.08) : AppColors.background)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.button)
                .stroke(isSelected ? AppColors.primary.opacity(0.2) : Color.clear, lineWidth: 2)
        )
        .overlay(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onSelect() }
                .padding(.trailing, 44)
        )
    }
}
