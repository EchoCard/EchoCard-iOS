//
//  AbnormalCallRecordsView.swift
//  CallMate
//
//  异常通话列表：展示未由 AI 代接的来电记录（时间 + 原因），供诊断排查。
//

import SwiftUI

struct AbnormalCallRecordsView: View {
    let language: Language
    @StateObject private var store = AbnormalCallRecordStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        f.locale = language == .zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        return f
    }

    private func reasonText(for record: AbnormalCallRecord) -> String {
        let reason: String
        switch record.reasonCode {
        case "contact_passthrough":
            reason = t("通讯录放行", "Contact passthrough")
        case "emergency_blocked":
            reason = t("紧急放行", "Emergency passthrough")
        case "standby":
            reason = t("待机模式未代接", "Standby mode, AI skipped")
        case "device_id_not_synced":
            reason = t("device-id 未同步", "Device-ID not synced")
        case "answer_failed":
            reason = t("应答失败", "Answer failed")
        case "network_unavailable":
            reason = t("网络不可用", "Network unavailable")
        case "websocket_connect_failed":
            reason = t("WebSocket 连不上", "WebSocket connect failed")
        default:
            reason = record.reasonCode
        }
        if let d = record.detail, !d.isEmpty {
            return "\(reason) (\(d))"
        }
        return reason
    }

    var body: some View {
        NavigationStack {
            List {
                if store.records.isEmpty {
                    Section {
                        Text(t("暂无异常通话记录", "No abnormal call records"))
                            .font(AppTypography.caption1)
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.lg)
                    }
                } else {
                    Section {
                        ForEach(store.records) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(dateFormatter.string(from: record.date))
                                    .font(AppTypography.caption2)
                                    .foregroundStyle(AppColors.textSecondary)
                                Text(reasonText(for: record))
                                    .font(AppTypography.caption1)
                                    .foregroundStyle(AppColors.textPrimary)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text(t("时间 · 原因", "Time · Reason"))
                    }
                }

                if !store.records.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Text(t("清空记录", "Clear Records"))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(t("异常通话记录", "Abnormal Call Records"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(t("关闭", "Close")) { dismiss() }
                }
            }
        }
        .confirmationDialog(t("清空异常通话记录？", "Clear abnormal call records?"), isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button(t("清空", "Clear"), role: .destructive) {
                store.clear()
            }
            Button(t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(t("仅清除本机列表，不影响设备。", "Only clears local list."))
        }
        .edgeSwipeBack(
            background: AppColors.backgroundSecondary.ignoresSafeArea(),
            perform: { dismiss() }
        )
    }
}
