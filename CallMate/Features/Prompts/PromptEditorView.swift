//
//  PromptEditorView.swift
//  CallMate
//
//  用于编辑和持久化 AI 服务器调试用的 Prompt
//

import SwiftUI

struct PromptEditorView: View {
    let language: Language
    let onClose: () -> Void
    
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    
    // UserDefaults keys
    private let promptKey = "ws_init_prompt"
    
    @State private var promptText: String = ""
    @State private var strategyText: String = ""
    @State private var showSaveConfirmation = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.x3) {
                    infoSection
                    promptSection
                }
                .padding(DS.Spacing.x2)
                .padding(.bottom, DS.Spacing.x6 * 2)
            }
            .background(AppColors.backgroundSecondary)
            .navigationTitle(t("调试 Prompt", "Debug Prompt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(DS.Typography.body.weight(.semibold))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: resetToDefault) {
                        Text(t("重置", "Reset"))
                            .font(DS.Typography.body.weight(.semibold))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: savePrompt) {
                    HStack(spacing: DS.Spacing.x1) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(t("保存", "Save"))
                    }
                    .font(DS.Typography.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .dsPrimaryButtonStyle()
                }
                .buttonStyle(.plain)
                .padding(DS.Spacing.x2)
                .background(AppColors.surface)
            }
            .onAppear {
                loadSavedValues()
            }
            .overlay {
                if showSaveConfirmation {
                    saveConfirmationOverlay
                }
            }
        }
        .edgeSwipeBack(
            background: AppColors.backgroundSecondary.ignoresSafeArea(),
            perform: onClose
        )
    }
    
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x2) {
            HStack(spacing: DS.Spacing.x1) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(AppColors.primary)
                Text(t("调试模式", "Debug Mode"))
                    .font(DS.Typography.body.weight(.semibold))
            }
            Text(t("WebSocket 初始化时会发送以下格式。", "WebSocket init sends the message below."))
                .font(DS.Typography.caption)
                .foregroundStyle(AppColors.textSecondary)
            
            VStack(alignment: .leading, spacing: DS.Spacing.x1) {
                Text(t("发送格式：", "Format:"))
                    .font(DS.Typography.caption)
                    .fontWeight(.semibold)
                Text("""
{
  "type": "hello",
  "initiate": {
    "prompt": "..."
  }
}
""")
                    .font(DS.Typography.caption)
                    .fontDesign(.monospaced)
                    .padding(DS.Spacing.x2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.backgroundTertiary)
                    .cornerRadius(DS.Radius.button)
            }
        }
        .padding(DS.Spacing.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCardStyle()
    }
    
    private var strategySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x1) {
            HStack {
                Text(t("处理策略（可选）", "Process Strategy (Optional)"))
                    .font(DS.Typography.body)
                    .fontWeight(.bold)
                Spacer()
                Text("\(strategyText.count) " + t("字符", "chars"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            
            TextField(t("输入自定义策略...", "Enter custom strategy..."), text: $strategyText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(DS.Spacing.x2)
                .background(AppColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.button)
                        .stroke(AppColors.border, lineWidth: 1)
                )
                .lineLimit(3...6)
        }
    }
    
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x2) {
            HStack {
                Text(t("Prompt 内容", "Prompt"))
                    .font(DS.Typography.body.weight(.semibold))
                Spacer()
                Text("\(promptText.count) " + t("字符", "chars"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                Button {
                    promptText = ""
                } label: {
                    HStack(spacing: DS.Spacing.x1) {
                        Image(systemName: "trash")
                        Text(t("清空", "Clear"))
                    }
                    .font(DS.Typography.caption)
                    .foregroundStyle(AppColors.error)
                    .padding(.horizontal, DS.Spacing.x2)
                    .padding(.vertical, 2)
                    .background(AppColors.error.opacity(0.1))
                    .cornerRadius(DS.Radius.button)
                }
                .buttonStyle(.plain)
            }
            
            TextEditor(text: $promptText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(DS.Spacing.x2)
                .frame(minHeight: 300)
                .background(AppColors.backgroundSecondary)
                .cornerRadius(DS.Radius.button)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.button)
                        .stroke(AppColors.border, lineWidth: 1)
                )
            
            Text(t("提示：点击「重置」恢复默认", "Tip: Tap 'Reset' to restore default"))
                .font(DS.Typography.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
        .padding(DS.Spacing.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCardStyle()
    }
    
    private var saveConfirmationOverlay: some View {
        VStack {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text(t("已保存", "Saved"))
                    .font(DS.Typography.body.weight(.medium))
            }
            .padding(.horizontal, DS.Spacing.x3)
            .padding(.vertical, DS.Spacing.x2)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .transition(.scale.combined(with: .opacity))
        .zIndex(100)
    }
    
    // MARK: - Actions
    
    private func loadSavedValues() {
        // 如果用户保存过自定义 prompt，使用保存的值；否则显示默认 prompt
        let savedPrompt = UserDefaults.standard.string(forKey: promptKey)
        if let savedPrompt, !savedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptText = savedPrompt
        } else {
            // 显示内置默认 prompt
            promptText = ""
        }
        strategyText = ProcessStrategyStore.processStrategyJSONString() ?? ""
    }
    
    private func savePrompt() {
        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStrategy = strategyText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedPrompt.isEmpty {
            UserDefaults.standard.removeObject(forKey: promptKey)
        } else {
            UserDefaults.standard.set(trimmedPrompt, forKey: promptKey)
        }
        
        if trimmedStrategy.isEmpty {
            ProcessStrategyStore.ensureDefaultIfNeeded()
            strategyText = ProcessStrategyStore.processStrategyJSONString() ?? ""
        } else {
            _ = ProcessStrategyStore.saveProcessStrategyJSONIfValid(trimmedStrategy)
            strategyText = ProcessStrategyStore.processStrategyJSONString() ?? trimmedStrategy
        }
        
        // 显示保存确认
        withAnimation(.spring(response: 0.3)) {
            showSaveConfirmation = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.spring(response: 0.3)) {
                showSaveConfirmation = false
            }
        }
    }
    
    private func resetToDefault() {
        // 重置为默认 prompt
        promptText = ""
        strategyText = ProcessStrategyStore.processStrategyJSONString() ?? ""
        UserDefaults.standard.removeObject(forKey: promptKey)
        
        withAnimation(.spring(response: 0.3)) {
            showSaveConfirmation = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.spring(response: 0.3)) {
                showSaveConfirmation = false
            }
        }
    }
}
