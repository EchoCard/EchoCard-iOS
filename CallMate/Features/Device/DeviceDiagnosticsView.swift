//
//  DeviceDiagnosticsView.swift
//  CallMate
//

import SwiftUI

struct DeviceDiagnosticsView: View {
    let language: Language
    @ObservedObject private var ble = CallMateBLEClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var autoPollingEnabled = false
    @State private var autoPollingTask: Task<Void, Never>?
    /// 调试开关：通话中是否跳过把服务器 `{type:"filler"}` 转发成 `play_filler` 给 MCU。
    /// 用于 A/B 验证 `docs/tts-uplink-stutter-pending.md` P0 候选 A（MCU 侧 filler
    /// mute gate 是否造成对方听 TTS 顿挫）。默认 false = 保持 filler 转发（跟发布版本
    /// 一致）；用户在 UI 里打开 toggle 才跳过转发，做 A/B 对比。
    @AppStorage("callmate.debug_disable_filler_forward") private var disableFillerForward = false
    /// 外呼：`audio_streaming` 是否允许拉起 `call_outbound` WS。默认 **true** = 禁止（仅等 `outgoing_answered`）；关掉开关 = 允许后备。配合 `[OutboundDiag]`。
    @AppStorage("callmate.outbound.disable_audio_streaming_ws_fallback") private var disableOutboundAudioStreamingWsFallback = true
    @State private var showCrashLog = false
    @State private var lastSetMac: String? = nil
    @State private var isMacWriting = false
    @State private var pmToastMessage: String? = nil
    @State private var pmToastSuccess: Bool = true

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private func bytesText(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }

    private func percentText(used: Int?, total: Int?) -> String {
        guard let used, let total, total > 0 else { return "--" }
        let p = (Double(used) / Double(total)) * 100.0
        return String(format: "%.1f%%", p)
    }

    private func cpuFreqText(_ mhz: Int?) -> String {
        guard let mhz, mhz > 0 else { return "--" }
        return "\(mhz) MHz"
    }

    private func bleAdvIntervalText(_ ms: Int?) -> String {
        guard let ms, ms >= 0 else { return "--" }
        return "\(ms) ms"
    }

    private func bleConnIntervalText(_ units: Int?) -> String {
        guard let units, units > 0 else { return "--" }
        let ms = (units * 125) / 100
        return "\(ms) ms (\(units) units)"
    }

    private func bleTxPowerText(_ dbm: Int?) -> String {
        guard let dbm else { return "--" }
        return "\(dbm) dBm"
    }

    private func deepSleepText(_ allowed: Int?) -> String {
        guard let allowed else { return "--" }
        return allowed != 0 ? t("允许", "Allowed") : t("禁止", "Disabled")
    }

    private func uptimeText(_ uptimeMs: Int?) -> String {
        guard let uptimeMs, uptimeMs >= 0 else { return "--" }
        let totalSeconds = uptimeMs / 1000
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if language == .zh {
            if days > 0 { return "\(days)天 \(hours)小时 \(minutes)分" }
            if hours > 0 { return "\(hours)小时 \(minutes)分 \(seconds)秒" }
            if minutes > 0 { return "\(minutes)分 \(seconds)秒" }
            return "\(seconds)秒"
        }

        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private var diag: DeviceDiagnostics? { ble.deviceDiagnostics }
    private var runtimeDeviceIDText: String {
        let trimmed = (ble.runtimeMCUDeviceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? t("未同步", "Not Synced") : trimmed
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // PM Toast
                    if let msg = pmToastMessage {
                        HStack(spacing: 8) {
                            Image(systemName: pmToastSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(pmToastSuccess ? Color(hex: "34C759") : Color(hex: "FF3B30"))
                            Text(msg)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(pmToastSuccess ? Color(hex: "34C759") : Color(hex: "FF3B30"))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((pmToastSuccess ? Color(hex: "34C759") : Color(hex: "FF3B30")).opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    // MARK: - Test & Debug
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(t("测试与调试", "Test & Debug"))

                        VStack(spacing: 0) {
                            diagToggleRow(
                                icon: "arrow.triangle.2.circlepath",
                                iconColor: Color(hex: "5856D6"),
                                title: t("自动轮询", "Auto Polling"),
                                subtitle: t("每 2 秒读取一次诊断数据", "Read diagnostics every 2 seconds"),
                                isOn: $autoPollingEnabled
                            )

                            cardDivider

                            diagToggleRow(
                                icon: "waveform.slash",
                                iconColor: Color(hex: "FF9500"),
                                title: t("禁用 AI 填充语", "Disable AI Fillers"),
                                subtitle: t("通话中不转发 play_filler（A/B 对方听 TTS 顿挫）",
                                            "Skip play_filler forwarding (A/B for remote TTS stutter)"),
                                isOn: $disableFillerForward
                            )

                            cardDivider

                            diagToggleRow(
                                icon: "phone.arrow.up.right",
                                iconColor: Color(hex: "34C759"),
                                title: t("禁用外呼 audio_streaming 云链后备", "Disable outbound audio_streaming WS fallback"),
                                subtitle: t("默认开启（仅等 outgoing_answered）。关掉本开关可恢复 audio_streaming 后备（旧 MCU）。日志搜 OutboundDiag",
                                            "On by default (outgoing_answered only). Turn OFF to allow audio_streaming fallback (legacy MCU). Grep [OutboundDiag]"),
                                isOn: $disableOutboundAudioStreamingWsFallback
                            )

                            cardDivider

                            NavigationLink {
                                AbnormalCallRecordsView(language: language)
                            } label: {
                                diagNavRow(
                                    icon: "phone.down.fill",
                                    iconColor: Color(hex: "FF3B30"),
                                    title: t("异常通话记录", "Abnormal Call Records"),
                                    subtitle: t("未代接原因与时间列表", "Time and reason list")
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }

                    // MARK: - System Info
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(t("系统信息", "System Info"))

                        VStack(spacing: 0) {
                            infoRow(t("芯片型号", "Chip"), ble.deviceChipName ?? "--")
                            cardDivider
                            infoRow("MCU Device-ID", runtimeDeviceIDText)
                            cardDivider
                            infoRow(t("CPU 使用率", "CPU Usage"), diag?.cpuUsage.map { String(format: "%.2f%%", $0) } ?? "--")
                            cardDivider
                            infoRow(t("CPU 频率", "CPU Freq"), cpuFreqText(diag?.cpuFreqMhz))
                            cardDivider
                            infoRow(t("运行时长", "Uptime"), uptimeText(diag?.uptimeMs))
                            cardDivider
                            infoRow(t("当前 Slot", "Active Slot"), diag?.activeSlotName ?? "--")
                            cardDivider
                            infoRow(t("OTA 状态", "OTA State"), diag?.otaState == 1 ? "PENDING" : (diag?.otaState == 0 ? "IDLE" : "--"))
                            cardDivider
                            infoRow("Deep Sleep", deepSleepText(diag?.deepSleepAllowed))
                        }
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }

                    // MARK: - CPU Frequency
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(t("CPU 频率", "CPU Frequency"))

                        VStack(alignment: .leading, spacing: 12) {
                            Text(t("选择 HCPU 频率（仅 SF32LB52X）；设置后立即生效。", "Select HCPU frequency (SF32LB52X only); takes effect immediately."))
                                .font(.system(size: 13))
                                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))

                            HStack(spacing: 8) {
                                ForEach([24, 48, 144, 240], id: \.self) { mhz in
                                    let isSelected = (diag?.cpuFreqMhz).map { $0 == mhz } ?? false
                                    chipButton(
                                        label: "\(mhz)",
                                        isSelected: isSelected,
                                        action: {
                                            pmToastMessage = language == .zh ? "已发送 \(mhz) MHz…" : "Sending \(mhz) MHz…"
                                            pmToastSuccess = true
                                            ble.sendCommand("cpu_freq", extra: ["mhz": mhz], expectAck: true)
                                        },
                                        disabled: !ble.isReady
                                    )
                                }
                            }

                            Text(t("24/48 MHz 低功耗；144/240 MHz 高性能。", "24/48 MHz low power; 144/240 MHz high performance."))
                                .font(.system(size: 13))
                                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                        }
                        .padding(16)
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }

                    // MARK: - BLE Intervals
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(t("BLE 间隔", "BLE Intervals"))

                        VStack(spacing: 0) {
                            infoRow(t("广播间隔", "Adv Interval"), bleAdvIntervalText(diag?.bleAdvIntervalMs))
                            cardDivider
                            infoRow(t("连接间隔", "Conn Interval"), bleConnIntervalText(diag?.bleConnIntervalUnits))
                            cardDivider
                            infoRow("TX Power", bleTxPowerText(diag?.bleTxPowerDbm))
                        }
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)

                        VStack(alignment: .leading, spacing: 12) {
                            Text(t("广播间隔（毫秒）", "Advertising Interval (ms)"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppColors.textPrimary)
                            HStack(spacing: 8) {
                                ForEach([20, 50, 100, 200, 500], id: \.self) { ms in
                                    let isSelected = (diag?.bleAdvIntervalMs).map { $0 == ms } ?? false
                                    chipButton(label: "\(ms)", isSelected: isSelected, action: {
                                        pmToastMessage = language == .zh ? "已发送 \(ms) ms…" : "Sending \(ms) ms…"
                                        pmToastSuccess = true
                                        ble.sendCommand("ble_adv_interval", extra: ["ms": ms], expectAck: true)
                                    }, disabled: !ble.isReady)
                                }
                            }

                            Text(t("连接间隔（毫秒）", "Connection Interval (ms)"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppColors.textPrimary)
                                .padding(.top, 4)
                            HStack(spacing: 8) {
                                ForEach([6, 12, 24, 60, 96], id: \.self) { units in
                                    let isSelected = (diag?.bleConnIntervalUnits).map { $0 == units } ?? false
                                    let ms = (units * 125) / 100
                                    chipButton(label: ms == 7 ? "7.5" : "\(ms)", isSelected: isSelected, action: {
                                        pmToastMessage = language == .zh ? "已发送 \(ms) ms…" : "Sending \(ms) ms…"
                                        pmToastSuccess = true
                                        ble.sendCommand("ble_conn_interval", extra: ["units": units], expectAck: true)
                                    }, disabled: !ble.isReady)
                                }
                            }

                            Text(t("发射功率（dBm）", "TX Power (dBm)"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppColors.textPrimary)
                                .padding(.top, 4)
                            HStack(spacing: 8) {
                                ForEach([0, 4, 10, 13, 16, 19], id: \.self) { dbm in
                                    let isSelected = (diag?.bleTxPowerDbm).map { $0 == dbm } ?? false
                                    chipButton(label: "\(dbm)", isSelected: isSelected, action: {
                                        pmToastMessage = language == .zh ? "已发送 \(dbm) dBm…" : "Sending \(dbm) dBm…"
                                        pmToastSuccess = true
                                        ble.sendCommand("ble_tx_power", extra: ["dbm": dbm], expectAck: true)
                                    }, disabled: !ble.isReady)
                                }
                            }
                        }
                        .padding(16)
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                        .padding(.top, 8)
                    }

                    // MARK: - Memory
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(t("内存", "Memory"))

                        VStack(spacing: 0) {
                            infoRow(t("Heap 已用", "Heap Used"), bytesText(diag?.heapUsedBytes))
                            cardDivider
                            infoRow(t("Heap 总量", "Heap Total"), bytesText(diag?.heapTotalBytes))
                            cardDivider
                            infoRow(t("Heap 峰值", "Heap Peak"), bytesText(diag?.heapPeakBytes))
                            cardDivider
                            infoRow(t("SRAM 已用", "SRAM Used"), bytesText(diag?.sramUsedBytes))
                            cardDivider
                            infoRow(t("SRAM 总量", "SRAM Total"), bytesText(diag?.sramTotalBytes))
                            cardDivider
                            infoRow(t("SRAM 使用率", "SRAM Usage"), percentText(used: diag?.sramUsedBytes, total: diag?.sramTotalBytes))
                        }
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }

                    // MARK: - PSRAM
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("PSRAM")

                        VStack(spacing: 0) {
                            infoRow(t("PSRAM 已用", "PSRAM Used"), bytesText(diag?.psramUsedBytes))
                            cardDivider
                            infoRow(t("PSRAM 总量", "PSRAM Total"), bytesText(diag?.psramTotalBytes))
                            cardDivider
                            infoRow(t("PSRAM 使用率", "PSRAM Usage"), percentText(used: diag?.psramUsedBytes, total: diag?.psramTotalBytes))
                        }
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }

                    // MARK: - FlashDB
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("FlashDB")

                        VStack(spacing: 0) {
                            infoRow(t("键数量", "Keys"), diag?.flashdbKeys.map(String.init) ?? "--")
                            cardDivider
                            infoRow(t("已用空间", "Used"), bytesText(diag?.flashdbUsedBytes))
                            cardDivider
                            infoRow(t("总空间", "Total"), bytesText(diag?.flashdbTotalBytes))
                            cardDivider
                            infoRow(t("使用率", "Usage"), percentText(used: diag?.flashdbUsedBytes, total: diag?.flashdbTotalBytes))
                        }
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }

                    // MARK: - BLE Speed Test
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(t("BLE 测速", "BLE Speed Test"))

                        VStack(spacing: 0) {
                            infoRow(
                                t("状态", "Status"),
                                ble.speedTestEnabled ? t("运行中", "Running") : t("未运行", "Stopped")
                            )
                            cardDivider
                            infoRow(
                                t("下行", "Downlink"),
                                String(format: "%.1f KB/s · %d pkt/s", ble.speedTestDownlinkKBps, ble.speedTestDownlinkPacketsPerSec)
                            )
                            cardDivider
                            infoRow(
                                t("上行", "Uplink"),
                                String(format: "%.1f KB/s · %d pkt/s", ble.speedTestUplinkKBps, ble.speedTestUplinkPacketsPerSec)
                            )
                        }
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)

                        HStack(spacing: 12) {
                            Button {
                                ble.startSpeedTest(payloadBytes: 160, intervalMs: 10)
                            } label: {
                                Text(t("开始测速", "Start"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(ble.speedTestEnabled ? Color(lightHex: "D1D5DB", darkHex: "4B5563") : Color(hex: "007AFF"))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .disabled(!ble.isAudioReady || ble.speedTestEnabled)

                            Button {
                                ble.stopSpeedTest()
                            } label: {
                                Text(t("停止测速", "Stop"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(ble.speedTestEnabled ? Color(hex: "FF9500") : Color(lightHex: "D1D5DB", darkHex: "4B5563"))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .disabled(!ble.speedTestEnabled)
                        }
                        .padding(.top, 8)
                    }

                    // MARK: - Tools
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(t("工具", "Tools"))

                        VStack(spacing: 0) {
                            if let mac = lastSetMac {
                                infoRow(t("上次写入 MAC", "Last Written MAC"), mac)
                                cardDivider
                            }

                            Button {
                                guard !isMacWriting else { return }
                                isMacWriting = true
                                let mac = ble.setRandomMacAddress()
                                lastSetMac = mac
                                Task {
                                    try? await Task.sleep(nanoseconds: 600_000_000)
                                    isMacWriting = false
                                }
                            } label: {
                                diagNavRow(
                                    icon: "network",
                                    iconColor: Color(hex: "5856D6"),
                                    title: t("随机生成 MAC 地址", "Randomize MAC Address"),
                                    subtitle: t("生成新地址并写入 MCU NVDS", "Generate and write to MCU NVDS"),
                                    showChevron: false,
                                    trailing: isMacWriting ? AnyView(ProgressView().scaleEffect(0.8)) : nil
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!ble.isReady || isMacWriting)

                            cardDivider

                            Button {
                                showCrashLog = true
                            } label: {
                                diagNavRow(
                                    icon: "exclamationmark.triangle.fill",
                                    iconColor: Color(hex: "FF3B30"),
                                    title: t("MCU 崩溃日志", "MCU Crash Log"),
                                    subtitle: t("查询、清除、复制崩溃记录", "View, clear, or copy crash records")
                                )
                            }
                            .buttonStyle(.plain)

                            cardDivider

                            NavigationLink {
                                MCURegistersView(language: language)
                            } label: {
                                diagNavRow(
                                    icon: "cpu",
                                    iconColor: Color(hex: "007AFF"),
                                    title: t("MCU 寄存器快照", "MCU Register Snapshot"),
                                    subtitle: t("按外设展开查看，支持搜索", "Expand by peripheral, searchable")
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }

                    // MARK: - Power / PM
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(t("电源管理", "Power Management"))

                        VStack(spacing: 0) {
                            pmButton(
                                icon: "bolt.slash",
                                iconColor: Color(hex: "FF9500"),
                                title: t("PM IO 下电", "PM IO Down"),
                                subtitle: t("BSP IO/外设下电，测漏电用", "BSP IO/peripheral power-down for leakage test"),
                                action: {
                                    pmToastMessage = language == .zh ? "已发送，等待回复…" : "Sent, waiting…"
                                    pmToastSuccess = true
                                    ble.sendCommand("pm_io_down", expectAck: true)
                                }
                            )

                            cardDivider

                            pmButton(
                                icon: "bolt",
                                iconColor: Color(hex: "34C759"),
                                title: t("PM IO 上电", "PM IO Up"),
                                action: {
                                    pmToastMessage = language == .zh ? "已发送，等待回复…" : "Sent, waiting…"
                                    pmToastSuccess = true
                                    ble.sendCommand("pm_io_up", expectAck: true)
                                }
                            )

                            cardDivider

                            pmButton(
                                icon: "lock",
                                iconColor: Color(hex: "5856D6"),
                                title: t("要 IDLE 锁", "Request IDLE Lock"),
                                subtitle: t("仅 IDLE，禁止进入 Deep Sleep", "IDLE only, no deep sleep"),
                                action: {
                                    pmToastMessage = language == .zh ? "已发送，等待回复…" : "Sent, waiting…"
                                    pmToastSuccess = true
                                    ble.sendCommand("pm_deepsleep", extra: ["enable": false], expectAck: true)
                                }
                            )

                            cardDivider

                            pmButton(
                                icon: "lock.open",
                                iconColor: Color(hex: "007AFF"),
                                title: t("释放 IDLE 锁", "Release IDLE Lock"),
                                subtitle: t("允许空闲时进入 Deep Sleep", "Allow deep sleep when idle"),
                                action: {
                                    pmToastMessage = language == .zh ? "已发送，等待回复…" : "Sent, waiting…"
                                    pmToastSuccess = true
                                    ble.sendCommand("pm_release_idle", expectAck: true)
                                }
                            )

                            cardDivider

                            pmButton(
                                icon: "moon.zzz",
                                iconColor: Color(hex: "007AFF"),
                                title: t("允许 Deep Sleep", "Deep Sleep On"),
                                subtitle: t("空闲时可进入 Deep Sleep 省电", "May enter deep sleep when idle"),
                                action: {
                                    pmToastMessage = language == .zh ? "已发送，等待回复…" : "Sent, waiting…"
                                    pmToastSuccess = true
                                    ble.sendCommand("pm_deepsleep", extra: ["enable": true], expectAck: true)
                                }
                            )

                            cardDivider

                            pmButton(
                                icon: "moon",
                                iconColor: Color(lightHex: "6B7280", darkHex: "9CA3AF"),
                                title: t("禁止 Deep Sleep", "Deep Sleep Off"),
                                action: {
                                    pmToastMessage = language == .zh ? "已发送，等待回复…" : "Sent, waiting…"
                                    pmToastSuccess = true
                                    ble.sendCommand("pm_deepsleep", extra: ["enable": false], expectAck: true)
                                }
                            )

                            cardDivider

                            pmButton(
                                icon: "gauge.with.needle",
                                iconColor: Color(hex: "FF9500"),
                                title: t("功耗测试 Idle", "Power Test Idle"),
                                subtitle: t("BLE 关 + 深睡，测待机电流", "BLE off + deep sleep for standby current"),
                                action: {
                                    pmToastMessage = language == .zh ? "已发送，等待回复…" : "Sent, waiting…"
                                    pmToastSuccess = true
                                    ble.sendCommand("power_test_idle", expectAck: true)
                                }
                            )

                            cardDivider

                            pmButton(
                                icon: "antenna.radiowaves.left.and.right.slash",
                                iconColor: Color(hex: "FF3B30"),
                                title: t("关 RF + LCPU Halt", "RF Off + LCPU Halt"),
                                subtitle: t("BLE 关 + 深睡 + halt LCPU", "BLE off + deep sleep + halt LCPU"),
                                action: {
                                    pmToastMessage = language == .zh ? "已发送，等待回复…" : "Sent, waiting…"
                                    pmToastSuccess = true
                                    ble.sendCommand("power_off_rf_lcpu_halt", expectAck: true)
                                }
                            )
                        }
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }

                    // MARK: - Danger Zone
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(t("危险操作", "Danger Zone"))

                        Button {
                            ble.sendCommand("shutdown", expectAck: true)
                        } label: {
                            HStack {
                                HStack(spacing: 12) {
                                    Image(systemName: "power")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(Color(hex: "FF3B30"))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t("彻底关机", "Shutdown"))
                                            .font(.system(size: 17))
                                            .foregroundStyle(Color(hex: "FF3B30"))
                                        Text(t("设备进入休眠，BLE 断开", "Device enters hibernate, BLE disconnects"))
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color(lightHex: "D1D5DB", darkHex: "4B5563"))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!ble.isReady)
                        .opacity(ble.isReady ? 1 : 0.5)
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }

                    // MARK: - Refresh
                    Button {
                        ble.requestDeviceDiagnostics()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .semibold))
                            Text(t("刷新诊断数据", "Refresh Diagnostics"))
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(Color(hex: "007AFF"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .background(AppColors.backgroundSecondary)
            .navigationTitle(t("设备诊断", "Device Diagnostics"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(t("关闭", "Close")) { dismiss() }
                        .font(.system(size: 17))
                        .foregroundStyle(Color(hex: "007AFF"))
                }
            }
        }
        .onReceive(ble.events) { evt in
            guard case let .ack(cmd, result) = evt else { return }
            guard cmd == "pm_io_down" || cmd == "pm_io_up" || cmd == "pm_deepsleep" || cmd == "pm_release_idle" || cmd == "power_test_idle" || cmd == "power_off_rf_lcpu_halt" || cmd == "cpu_freq" || cmd == "ble_adv_interval" || cmd == "ble_conn_interval" || cmd == "ble_tx_power" else { return }
            if result == 0 {
                pmToastMessage = language == .zh ? "发送成功" : "Sent successfully"
                pmToastSuccess = true
                if cmd == "cpu_freq" || cmd == "ble_adv_interval" || cmd == "ble_conn_interval" || cmd == "ble_tx_power" {
                    ble.requestDeviceDiagnostics()
                }
            } else {
                pmToastMessage = language == .zh ? "发送失败 (code: \(result))" : "Failed (code: \(result))"
                pmToastSuccess = false
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                pmToastMessage = nil
            }
        }
        .onAppear {
            ble.requestDeviceDiagnostics()
        }
        .onChange(of: autoPollingEnabled) { _, enabled in
            if enabled {
                startAutoPolling()
            } else {
                stopAutoPolling()
            }
        }
        .onDisappear {
            stopAutoPolling()
        }
        .edgeSwipeBack(
            background: AppColors.backgroundSecondary.ignoresSafeArea(),
            perform: { dismiss() }
        )
        .sheet(isPresented: $showCrashLog) {
            MCUCrashLogView(language: language)
        }
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
            .textCase(.uppercase)
            .tracking(1.2)
            .padding(.leading, 16)
            .padding(.bottom, 8)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(AppColors.separator)
            .frame(height: 0.5)
            .padding(.leading, 56)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(AppColors.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func diagNavRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String? = nil,
        showChevron: Bool = true,
        trailing: AnyView? = nil
    ) -> some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(iconColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17))
                        .foregroundStyle(AppColors.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                    }
                }
            }

            Spacer(minLength: 8)

            if let trailing {
                trailing
            } else if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(lightHex: "D1D5DB", darkHex: "4B5563"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func diagToggleRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(iconColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func pmButton(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(iconColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 17))
                            .foregroundStyle(AppColors.textPrimary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                        }
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!ble.isReady)
        .opacity(ble.isReady ? 1 : 0.5)
    }

    private func chipButton(label: String, isSelected: Bool, action: @escaping () -> Void, disabled: Bool) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Color(hex: "007AFF") : AppColors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color(hex: "007AFF").opacity(0.12) : Color(lightHex: "F2F2F7", darkHex: "2C2C2E"))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func startAutoPolling() {
        stopAutoPolling()
        autoPollingTask = Task { @MainActor in
            while !Task.isCancelled && autoPollingEnabled {
                ble.requestDeviceDiagnostics()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopAutoPolling() {
        autoPollingTask?.cancel()
        autoPollingTask = nil
    }
}
