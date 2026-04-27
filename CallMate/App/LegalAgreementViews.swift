import SwiftUI
import WebKit
import UIKit

enum LegalDocumentType: String, Identifiable {
    case userAgreement
    case privacyPolicy

    var id: String { rawValue }

    func title(for language: Language) -> String {
        switch (self, language) {
        case (.userAgreement, .zh):
            return "用户协议"
        case (.userAgreement, .en):
            return "User Agreement"
        case (.privacyPolicy, .zh):
            return "隐私协议"
        case (.privacyPolicy, .en):
            return "Privacy Policy"
        }
    }

    var fileBaseName: String {
        switch self {
        case .userAgreement:
            return "callmate_user_agreement"
        case .privacyPolicy:
            return "callmate_privacy_policy"
        }
    }
}

struct LegalConsentOverlay: View {
    let language: Language
    let onConfirm: () -> Void
    let onExit: () -> Void
    let onOpenUserAgreement: () -> Void
    let onOpenPrivacyPolicy: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.6 : 0.4)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)

            VStack(spacing: 0) {
                Text(t("欢迎使用 EchoCard", "Welcome to EchoCard"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(t("欢迎您使用 EchoCard 服务！",
                               "Welcome to EchoCard!"))
                            .font(.system(size: 13))
                            .foregroundStyle(Color(lightHex: "4B5563", darkHex: "D1D5DB"))

                        Text(buildParagraph1())
                            .font(.system(size: 13))
                            .foregroundStyle(Color(lightHex: "4B5563", darkHex: "D1D5DB"))
                            .tint(AppColors.textPrimary)

                        Text(buildParagraph2())
                            .font(.system(size: 13))
                            .foregroundStyle(Color(lightHex: "4B5563", darkHex: "D1D5DB"))
                            .tint(AppColors.textPrimary)

                        Text(buildParagraph3())
                            .font(.system(size: 13))
                            .foregroundStyle(Color(lightHex: "4B5563", darkHex: "D1D5DB"))
                            .tint(AppColors.textPrimary)

                        Text(t("如您同意以上内容，请点击\u{201C}同意\u{201D}，正式开启服务！",
                               "If you agree, tap \"Agree\" to start using the service!"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppColors.textPrimary)
                            .padding(.top, 4)
                    }
                    .padding(14)
                    .background(Color(lightHex: "F9FAFB", darkHex: "2C2C2E"))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .environment(\.openURL, OpenURLAction { url in
                        switch url.absoluteString {
                        case "callmate://legal/user":
                            onOpenUserAgreement()
                        case "callmate://legal/privacy":
                            onOpenPrivacyPolicy()
                        default:
                            break
                        }
                        return .handled
                    })
                }
                .frame(maxHeight: 220)
                .padding(.bottom, 24)

                VStack(spacing: 6) {
                    Button(action: onExit) {
                        Text(t("不同意", "Disagree"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "9CA3AF"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    Button(action: onConfirm) {
                        Text(t("同意", "Agree"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(hex: "0047FF"))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(colorScheme == .dark ? Color(hex: "1C1C1E") : .white)
                    .shadow(color: .black.opacity(0.15), radius: 30, x: 0, y: 10)
            )
            .padding(.horizontal, 24)
        }
    }

    private func buildParagraph1() -> AttributedString {
        var result = AttributedString()

        var p1 = AttributedString(t("为了更好地保障您的个人权益，在正式开启使用服务前，请您审慎阅读",
                                     "To protect your rights, please carefully read "))
        p1.font = .system(size: 13)
        result += p1

        var link1 = AttributedString(t("《EchoCard 用户协议》", "EchoCard User Agreement"))
        link1.font = .system(size: 13, weight: .bold)
        link1.link = URL(string: "callmate://legal/user")
        result += link1

        var sep = AttributedString(t("、", ", "))
        sep.font = .system(size: 13)
        result += sep

        var link2 = AttributedString(t("《EchoCard 隐私政策》", "EchoCard Privacy Policy"))
        link2.font = .system(size: 13, weight: .bold)
        link2.link = URL(string: "callmate://legal/privacy")
        result += link2

        var p2 = AttributedString(t("，以便了解我们为您提供的服务内容及形式、使用本服务需遵守的规范，同时了解我们如何收集、使用、存储、保存及保护、对外提供您的个人信息以及您如何向我们行使您的法定权利。",
                                     " to understand our service terms and how we handle your personal data."))
        p2.font = .system(size: 13)
        result += p2

        return result
    }

    private func buildParagraph2() -> AttributedString {
        var result = AttributedString()

        var p1 = AttributedString(t("对于", "For "))
        p1.font = .system(size: 13)
        result += p1

        var link1 = AttributedString(t("《EchoCard 用户协议》", "EchoCard User Agreement"))
        link1.font = .system(size: 13, weight: .bold)
        link1.link = URL(string: "callmate://legal/user")
        result += link1

        var p2 = AttributedString(t("，您点击同意即代表您已阅读并同意相关内容。",
                                     ", tapping agree means you have read and accepted the terms."))
        p2.font = .system(size: 13)
        result += p2

        return result
    }

    private func buildParagraph3() -> AttributedString {
        var result = AttributedString()

        var p1 = AttributedString(t("对于", "For "))
        p1.font = .system(size: 13)
        result += p1

        var link1 = AttributedString(t("《EchoCard 隐私政策》", "EchoCard Privacy Policy"))
        link1.font = .system(size: 13, weight: .bold)
        link1.link = URL(string: "callmate://legal/privacy")
        result += link1

        var p2 = AttributedString(t("，您点击同意仅代表您已知悉本服务提供的基本功能，并同意我们收集基本功能所需的必要个人信息，并不代表您已同意我们为提供附加功能收集非必要个人信息。对于非必要的个人信息处理，会在您开启具体附加服务前单独征求您的同意。",
                                     ", tapping agree only means you acknowledge the basic functions and agree to necessary data collection. Non-essential data processing will require separate consent before enabling additional features."))
        p2.font = .system(size: 13)
        result += p2

        return result
    }
}

struct LegalDocumentView: View {
    let language: Language
    let document: LegalDocumentType
    @Environment(\.dismiss) private var dismiss

    private var documentURL: URL? {
        if let direct = Bundle.main.url(forResource: document.fileBaseName, withExtension: "html") {
            return direct
        }
        if let inResources = Bundle.main.url(forResource: document.fileBaseName, withExtension: "html", subdirectory: "Resources") {
            return inResources
        }
        return nil
    }

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        NavigationStack {
            Group {
                if let fileURL = documentURL {
                    LocalHTMLWebView(fileURL: fileURL)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    VStack(spacing: AppSpacing.sm) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(AppColors.warning)
                        Text(t("未找到本地协议文件", "Local agreement file not found"))
                            .font(AppTypography.body)
                            .foregroundColor(AppColors.textPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColors.background)
                }
            }
            .navigationTitle(document.title(for: language))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(t("关闭", "Close")) {
                        dismiss()
                    }
                }
            }
        }
        .edgeSwipeBack(
            background: AppColors.backgroundSecondary.ignoresSafeArea(),
            perform: { dismiss() }
        )
    }
}

private struct LocalHTMLWebView: UIViewRepresentable {
    let fileURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .white
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let directoryURL = fileURL.deletingLastPathComponent()
        webView.loadFileURL(fileURL, allowingReadAccessTo: directoryURL)
    }
}

enum AppTermination {
    static func exitApplication() {
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exit(0)
        }
    }
}
