//
//  MCUCrashLogView.swift
//  CallMate
//
//  Displays the MCU crash log stored in flash ("dfu" FlashDB partition).
//  Features: query, clear, copy to clipboard.
//

import SwiftUI

struct MCUCrashLogView: View {
    let language: Language
    @ObservedObject private var ble = CallMateBLEClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirm = false
    @State private var copiedFeedback   = false

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                stateSection
                if case .found(let log) = ble.mcuCrashLogState {
                    infoSection(log)
                    actionsSection(log)
                } else {
                    emptyActionsSection
                }
            }
            .navigationTitle(t("MCU 崩溃日志", "MCU Crash Log"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(t("关闭", "Close")) { dismiss() }
                }
            }
        }
        .onAppear { ble.requestMCUCrashLog() }
        .edgeSwipeBack(
            background: AppColors.backgroundSecondary.ignoresSafeArea(),
            perform: { dismiss() }
        )
        .confirmationDialog(
            t("确认清除崩溃日志？", "Clear crash log?"),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(t("清除", "Clear"), role: .destructive) {
                ble.clearMCUCrashLog()
            }
            Button(t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(t("清除后无法恢复。", "This action cannot be undone."))
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var stateSection: some View {
        Section {
            switch ble.mcuCrashLogState {
            case .idle:
                statusRow(icon: "questionmark.circle", color: AppColors.textSecondary,
                          text: t("点击刷新以查询", "Tap Refresh to query"))

            case .loading:
                HStack(spacing: AppSpacing.sm) {
                    ProgressView().scaleEffect(0.85)
                    Text(t("查询中…", "Querying…"))
                        .font(AppTypography.caption1)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .padding(.vertical, AppSpacing.xs)

            case .found:
                statusRow(icon: "exclamationmark.triangle.fill", color: AppColors.warning,
                          text: t("发现崩溃记录", "Crash record found"))

            case .notFound:
                statusRow(icon: "checkmark.circle.fill", color: AppColors.success,
                          text: t("无崩溃记录（运行正常）", "No crash record (healthy)"))

            case .error(let msg):
                statusRow(icon: "xmark.circle.fill", color: AppColors.error, text: msg)
            }
        } header: {
            Text(t("状态", "Status"))
        }
    }

    @ViewBuilder
    private func infoSection(_ log: MCUCrashLog) -> some View {
        Section {
            row(t("崩溃类型", "Crash Type"), log.crashTypeName, highlight: true)
            row(t("崩溃时运行时长", "Uptime at Crash"), log.uptimeFormatted)
            row(t("崩溃线程", "Thread"), log.thread)
        } header: { Text(t("概览", "Overview")) }

        if log.pc != 0 || log.lr != 0 {
            Section {
                row("PC", hex(log.pc))
                row("LR", hex(log.lr))
            } header: { Text(t("寄存器", "Registers")) }
        }

        if log.cfsr != 0 || log.hfsr != 0 {
            Section {
                row("CFSR", hex(log.cfsr))
                row("HFSR", hex(log.hfsr))
                row(t("原因", "Reason"), cfsrDescription(log.cfsr))
            } header: { Text("Fault Status") }
        }

        Section {
            Text(log.detail)
                .font(AppTypography.caption1)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: { Text(t("详情", "Detail")) }

        if !log.backtrace.isEmpty {
            Section {
                ForEach(Array(log.backtrace.enumerated()), id: \.offset) { i, addr in
                    HStack {
                        Text("#\(i)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(width: 28, alignment: .leading)
                        Text(String(format: "0x%08X", addr))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AppColors.textPrimary)
                    }
                }
                Text(t("使用 addr2line -e fw.elf <地址> 解码", "Decode with: addr2line -e fw.elf <addr>"))
                    .font(AppTypography.caption2)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text(t("调用链（启发式）", "Backtrace (heuristic)")) }
        }
    }

    @ViewBuilder
    private func actionsSection(_ log: MCUCrashLog) -> some View {
        Section {
            // Copy
            Button {
                UIPasteboard.general.string = log.plainText
                withAnimation { copiedFeedback = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation { copiedFeedback = false }
                }
            } label: {
                HStack {
                    Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                        .frame(width: 22)
                        .foregroundStyle(copiedFeedback ? AppColors.success : AppColors.primary)
                    Text(copiedFeedback ? t("已复制", "Copied!") : t("复制到剪贴板", "Copy to Clipboard"))
                        .font(AppTypography.bodyEmphasized)
                        .foregroundStyle(copiedFeedback ? AppColors.success : AppColors.primary)
                }
            }
            .buttonStyle(.plain)

            // Refresh
            Button {
                ble.requestMCUCrashLog()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise").frame(width: 22)
                    Text(t("刷新", "Refresh"))
                        .font(AppTypography.bodyEmphasized)
                }
            }
            .buttonStyle(.plain)

            // Clear
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash").frame(width: 22)
                    Text(t("清除崩溃日志", "Clear Crash Log"))
                        .font(AppTypography.bodyEmphasized)
                }
            }
            .buttonStyle(.plain)
        } header: { Text(t("操作", "Actions")) }
    }

    @ViewBuilder
    private var emptyActionsSection: some View {
        Section {
            Button {
                ble.requestMCUCrashLog()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise").frame(width: 22)
                    Text(t("刷新", "Refresh"))
                        .font(AppTypography.bodyEmphasized)
                }
            }
            .buttonStyle(.plain)
        } header: { Text(t("操作", "Actions")) }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 16, weight: .semibold))
            Text(text)
                .font(AppTypography.caption1)
                .foregroundStyle(AppColors.textPrimary)
        }
        .padding(.vertical, AppSpacing.xs)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(AppTypography.caption1)
            Spacer()
            Text(value)
                .font(AppTypography.caption1)
                .foregroundStyle(highlight ? AppColors.warning : AppColors.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func hex(_ v: UInt32) -> String {
        String(format: "0x%08X", v)
    }

    private func cfsrDescription(_ cfsr: UInt32) -> String {
        if cfsr & 0xFFFF0000 != 0 { return "UsageFault" }
        if cfsr & 0x0000FF00 != 0 { return "BusFault" }
        if cfsr & 0x000000FF != 0 { return "MemManageFault" }
        return t("未知", "Unknown")
    }
}
