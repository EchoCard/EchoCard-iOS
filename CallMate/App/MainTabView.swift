//
//  MainTabView.swift
//  CallMate
//

import SwiftUI

struct MainTabView: View {
    let language: Language
    let setLanguage: (Language) -> Void
    let onDisconnect: () -> Void
    let onFactoryReset: () -> Void
    let onDeleteAllLocalData: () -> Void
    let onRebind: () -> Void

    @ObservedObject private var liveTranscriptRouter: LiveTranscriptNotificationRouter

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    @State private var showAISheet = false
    @State private var showAIFabOnHome = true

    @MainActor
    init(
        language: Language,
        setLanguage: @escaping (Language) -> Void,
        onDisconnect: @escaping () -> Void,
        onFactoryReset: @escaping () -> Void,
        onDeleteAllLocalData: @escaping () -> Void,
        onRebind: @escaping () -> Void,
        liveTranscriptRouter: LiveTranscriptNotificationRouter? = nil
    ) {
        self.language = language
        self.setLanguage = setLanguage
        self.onDisconnect = onDisconnect
        self.onFactoryReset = onFactoryReset
        self.onDeleteAllLocalData = onDeleteAllLocalData
        self.onRebind = onRebind
        _liveTranscriptRouter = ObservedObject(wrappedValue: liveTranscriptRouter ?? .shared)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CallsView(
                language: language,
                setLanguage: setLanguage,
                onDisconnect: onDisconnect,
                onFactoryReset: onFactoryReset,
                onDeleteAllLocalData: onDeleteAllLocalData,
                onRebind: onRebind,
                showsSettingsShortcut: true,
                showsAIFab: false,
                liveTranscriptRouter: liveTranscriptRouter,
                onHomeVisibilityChange: { isOnHome in
                    showAIFabOnHome = isOnHome
                }
            )

            if !showAISheet && showAIFabOnHome {
                aiFab
                    .transition(.scale.combined(with: .opacity))
                    .padding(.trailing, 20)
                    .padding(.bottom, 32)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showAISheet)
        .accessibilityIdentifier("main-tab-view")
        .sheet(isPresented: $showAISheet) {
            AISecView(language: language)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: liveTranscriptRouter.overlayDismissToken) { _, _ in
            if showAISheet {
                showAISheet = false
            }
        }
    }

    // MARK: - Floating AI Button

    private let fabSize: CGFloat = 64

    private var aiFab: some View {
        Group {
            if #available(iOS 26.0, *) {
                Button { showAISheet = true } label: {
                    aiFabLabel
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .shadow(color: AppColors.primary.opacity(0.16), radius: 16, x: 0, y: 6)
            } else {
                Button { showAISheet = true } label: {
                    aiFabLabel
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                )
                .shadow(color: AppColors.primary.opacity(0.16), radius: 16, x: 0, y: 6)
                .shadow(color: .white.opacity(0.16), radius: 1, x: 0, y: -1)
            }
        }
    }

    private var aiFabLabel: some View {
        VStack(spacing: 2) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
            Text(t("AI分身", "Avatar"))
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(AppColors.primary)
        .frame(width: fabSize, height: fabSize)
    }
}

#Preview {
    MainTabView(
        language: .zh,
        setLanguage: { _ in },
        onDisconnect: {},
        onFactoryReset: {},
        onDeleteAllLocalData: {},
        onRebind: {}
    )
}
