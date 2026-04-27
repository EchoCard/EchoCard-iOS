//
//  ANCSPermissionGuideView.swift
//  CallMate
//

import SwiftUI

struct ANCSPermissionGuideView: View {
    let language: Language
    let onDismiss: () -> Void

    @ObservedObject private var ble = CallMateBLEClient.shared
    @State private var isVerifying = false

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: DS.Spacing.x3) {
                    headerSection
                    stepsSection
                    verifyButton
                    whySection
                }
                .padding(DS.Spacing.x3)
                .padding(.bottom, DS.Spacing.x4)
            }
            .background(AppColors.background)
            .navigationTitle(t("开启通知权限", "Enable Notifications"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppColors.textSecondary)
                            .font(.title3)
                    }
                }
            }
        }
        .onChange(of: ble.deviceANCSVerifyCount) { _, _ in
            guard isVerifying else { return }
            isVerifying = false
            if ble.deviceANCSEnabled == true {
                onDismiss()
            }
        }
    }

    // MARK: - Verify Button

    private var verifyButton: some View {
        Button {
            isVerifying = true
            ble.verifyANCSPermission()
        } label: {
            HStack(spacing: 8) {
                if isVerifying {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "checkmark.shield")
                }
                Text(isVerifying
                     ? t("验证中…", "Verifying…")
                     : t("我已开启，验证一下", "I've enabled it, verify now"))
            }
            .font(DS.Typography.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.x2)
            .background(isVerifying ? AppColors.textSecondary : AppColors.primary)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .shadow(color: AppColors.primary.opacity(0.3), radius: 12, y: 6)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isVerifying)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: DS.Spacing.x2) {
            ZStack {
                Circle()
                    .fill(AppColors.warning.opacity(0.15))
                    .frame(width: 88, height: 88)

                Image(systemName: "bell.badge.slash.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(AppColors.warning)
            }

            Text(t("ANCS 通知权限未开启", "ANCS Notifications Disabled"))
                .font(DS.Typography.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text(t(
                "EchoCard 需要 iPhone 的通知共享权限才能检测来电和通话状态。请按以下步骤开启。",
                "EchoCard needs iPhone notification sharing to detect calls. Follow the steps below to enable it."
            ))
            .font(DS.Typography.body)
            .foregroundStyle(AppColors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Spacing.x2)
        }
        .padding(.top, DS.Spacing.x2)
    }

    // MARK: - Steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepRow(
                number: 1,
                icon: "gear",
                title: t("打开 iPhone「设置」", "Open iPhone Settings"),
                subtitle: t("在主屏幕找到「设置」App", "Find the Settings app on your Home Screen"),
                isLast: false
            )
            stepRow(
                number: 2,
                icon: "bluetooth",
                title: t("进入「蓝牙」", "Go to Bluetooth"),
                subtitle: t("点击 设置 → 蓝牙", "Tap Settings → Bluetooth"),
                isLast: false
            )
            stepRow(
                number: 3,
                icon: "info.circle",
                title: t("找到 EchoCard 设备", "Find EchoCard Device"),
                subtitle: t("在「我的设备」列表中找到 EchoCard，点击右侧 ⓘ 按钮", "In My Devices list, find EchoCard and tap the ⓘ button"),
                isLast: false
            )
            stepRow(
                number: 4,
                icon: "bell.badge",
                title: t("开启「共享系统通知」", "Enable Share System Notifications"),
                subtitle: t("将「共享系统通知」开关打开即可", "Turn on the Share System Notifications toggle"),
                isLast: true
            )
        }
        .padding(DS.Spacing.x2)
        .background(AppColors.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .stroke(AppColors.border, lineWidth: 1)
        )
    }

    private func stepRow(number: Int, icon: String, title: String, subtitle: String, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.x2) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(AppColors.primary)
                        .frame(width: 28, height: 28)
                    Text("\(number)")
                        .font(DS.Typography.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }
                if !isLast {
                    Rectangle()
                        .fill(AppColors.border)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.primary)
                    Text(title)
                        .font(DS.Typography.body)
                        .fontWeight(.semibold)
                }
                Text(subtitle)
                    .font(DS.Typography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(.bottom, isLast ? 0 : DS.Spacing.x3)
        }
        .padding(.vertical, DS.Spacing.x1)
    }

    // MARK: - Why

    private var whySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x1) {
            Label(t("为什么需要此权限？", "Why is this needed?"), systemImage: "questionmark.circle")
                .font(DS.Typography.caption)
                .fontWeight(.bold)
                .foregroundStyle(AppColors.accent)

            Text(t(
                "ANCS（Apple 通知中心服务）是 iOS 向蓝牙配件共享通知的标准协议。EchoCard 通过 ANCS 检测来电，自动启动 AI 代接。关闭此权限后，EchoCard 将无法感知来电。",
                "ANCS (Apple Notification Center Service) is how iOS shares notifications with Bluetooth accessories. EchoCard uses ANCS to detect incoming calls and activate AI call screening. Without it, EchoCard cannot detect calls."
            ))
            .font(DS.Typography.caption)
            .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.x2)
        .background(AppColors.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .stroke(AppColors.accent.opacity(0.2), lineWidth: 1)
        )
    }

}

// MARK: - Dashboard Warning Banner

struct ANCSWarningBanner: View {
    let language: Language
    let onTap: () -> Void

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AppColors.warning)
                    .frame(width: 36, height: 36)
                    .background(AppColors.warning.opacity(0.15))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(t("ANCS 通知未授权", "ANCS Notifications Denied"))
                        .font(DS.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(t("EchoCard 无法检测来电，点击查看解决方法", "EchoCard can't detect calls. Tap to fix."))
                        .font(DS.Typography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(AppSpacing.md)
            .background(AppColors.warning.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .stroke(AppColors.warning.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
