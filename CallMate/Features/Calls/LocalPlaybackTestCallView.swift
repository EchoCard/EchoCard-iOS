//
//  LocalPlaybackTestCallView.swift
//  CallMate
//

import SwiftUI

struct LocalPlaybackTestCallView: View {
    let language: Language
    let incomingCall: CallMateIncomingCall
    let onClose: () -> Void

    @ObservedObject var controller: LocalPlaybackTestController

    @State private var didStart: Bool = false

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            controls
        }
        .onAppear {
            guard !didStart else { return }
            didStart = true
            controller.start(incomingCall: incomingCall)
        }
        .onChange(of: controller.status) { _, newStatus in
            if newStatus == .ended {
                onClose()
            }
        }
    }

    private var header: some View {
        VStack(spacing: DS.Spacing.x1) {
            Text(t("离线本地回放测试", "Offline Local Playback Test"))
                .font(DS.Typography.body.weight(.semibold))
            Text("\(incomingCall.caller.isEmpty ? t("未知来电", "Unknown Caller") : incomingCall.caller) · \(incomingCall.number)")
                .font(DS.Typography.caption)
                .foregroundStyle(AppColors.textSecondary)
            Text(statusText)
                .font(DS.Typography.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
        .padding(.vertical, DS.Spacing.x2)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return t("准备中…", "Preparing…")
        case .ringing: return t("等待接通…", "Waiting…")
        case .connected: return t("已接通（正在下发本地录音）", "Connected (sending local audio)")
        case .ended: return t("已结束", "Ended")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x2) {
            if let err = controller.lastError {
                Text(t("错误：", "Error: ") + err)
                    .font(DS.Typography.body)
                    .foregroundStyle(AppColors.error)
            }
            if let name = controller.sourceRecordingName {
                Text(t("音频来源：内置 WAV（固定 TTS）", "Source: bundled WAV (fixed TTS)"))
                    .font(DS.Typography.body)
                Text(name)
                    .font(DS.Typography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(2)
            } else {
                Text(t("音频来源：加载中…", "Source: loading…"))
                    .font(DS.Typography.body)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Text(t("说明：该模式不走云端；MCU 将停止 BLE 下行音频，仅验证 iOS→MCU→经典蓝牙 uplink 链路。",
                   "Note: No cloud; MCU suppresses BLE downlink audio and we validate iOS→MCU→Classic BT uplink."))
                .font(DS.Typography.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.x2)
    }

    private var controls: some View {
        HStack(spacing: DS.Spacing.x2) {
            Button(role: .destructive) {
                controller.end()
            } label: {
                Text(t("结束测试并挂断", "End Test & Hang up"))
                    .font(DS.Typography.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.x2)
                    .background(AppColors.error.opacity(0.12))
                    .foregroundStyle(AppColors.error)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
            }
            .buttonStyle(.plain)
        }
        .padding(DS.Spacing.x2)
    }
}

