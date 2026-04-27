//
//  LatencyTestView.swift
//  CallMate
//
//  UI for HFP round-trip latency test (see docs/LATENCY_TEST_DESIGN.md).
//

import SwiftUI

struct LatencyTestView: View {
    let language: Language
    @StateObject private var runner = LatencyTestRunner.shared
    @ObservedObject private var ble = CallMateBLEClient.shared
    @ObservedObject private var continuousAnalyzer: ContinuousLatencyAnalyzer

    init(language: Language) {
        self.language = language
        _continuousAnalyzer = ObservedObject(wrappedValue: LatencyTestRunner.shared.continuousAnalyzer)
    }

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    private func localizedStatus(_ raw: String) -> String {
        switch raw {
        case "":
            return t("未开始", "Idle")
        case "Starting…":
            return t("开始中…", "Starting…")
        case "Connecting HFP…":
            return t("连接 HFP…", "Connecting HFP…")
        case "Waiting for SCO…":
            return t("等待 SCO…", "Waiting for SCO…")
        case "Starting latency encoder…":
            return t("启动延迟编码…", "Starting latency encoder…")
        case "Playing square wave & recording…":
            return t("播放方波并录音…", "Playing square wave & recording…")
        case "Completed":
            return t("已完成", "Completed")
        case "Stopped":
            return t("已停止", "Stopped")
        case "Error":
            return t("错误", "Error")
        case "BLE not ready":
            return t("BLE 未就绪", "BLE not ready")
        default:
            return raw
        }
    }
    private func measurementTitle(_ id: String) -> String {
        switch id {
        case "playback_to_ble":
            return t("播放方波到 BLE 环回", "Playback to BLE loopback")
        case "ble_to_recording":
            return t("BLE 环回到录音", "BLE loopback to recording")
        case "total":
            return t("总延时", "Total latency")
        default:
            return id
        }
    }
    private func traceTitle(_ kind: LatencyWaveformKind) -> String {
        switch kind {
        case .playback:
            return t("播放方波", "Playback Square Wave")
        case .bleLoopback:
            return t("BLE 环回解码", "Decoded BLE Loopback")
        case .microphone:
            return t("本地录音", "Local Recording")
        }
    }
    private func traceColor(_ kind: LatencyWaveformKind) -> Color {
        switch kind {
        case .playback:
            return .blue
        case .bleLoopback:
            return .orange
        case .microphone:
            return .green
        }
    }
    private func markerTitle(_ id: String) -> String {
        switch id {
        case "playback":
            return t("播放开始", "Playback start")
        case "playback_to_ble":
            return t("BLE 首包", "BLE first packet")
        case "total":
            return t("录音首边沿", "Recording first edge")
        default:
            return id
        }
    }
    private var timelineMarkers: [LatencyTimelineMarker] {
        var markers: [LatencyTimelineMarker] = [
            .init(id: "playback", title: markerTitle("playback"), timeMs: 0, color: traceColor(.playback))
        ]
        for measurement in runner.stageMeasurements where measurement.id == "playback_to_ble" || measurement.id == "total" {
            if let timeMs = measurement.milliseconds {
                let kind: LatencyWaveformKind = measurement.id == "playback_to_ble" ? .bleLoopback : .microphone
                markers.append(.init(id: measurement.id, title: markerTitle(measurement.id), timeMs: timeMs, color: traceColor(kind)))
            }
        }
        return markers
    }

    var body: some View {
        List {
            Section {
                Text(t("延迟测试通过 HFP 环回：播放方波 → 经典蓝牙 → MCU → BLE → iOS 环回 → MCU → 经典蓝牙 → 录音，测量整链延迟。",
                      "Latency test: play square wave → HFP → MCU → BLE → echo → MCU → HFP → record; measure round-trip latency."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(t("状态", "Status")) {
                if runner.isRunning {
                    HStack {
                        ProgressView()
                        Text(localizedStatus(runner.statusMessage))
                    }
                } else {
                    Text(localizedStatus(runner.statusMessage))
                }
                if let err = runner.errorMessage {
                    Text(err)
                        .foregroundStyle(.red)
                }
                if !runner.stageMeasurements.isEmpty {
                    ForEach(runner.stageMeasurements) { measurement in
                        HStack {
                            Text(measurementTitle(measurement.id))
                            Spacer()
                            Text(measurement.milliseconds.map { "\(Int($0)) ms" } ?? "--")
                                .font(.headline)
                        }
                    }
                }
            }

            if !runner.waveformTraces.isEmpty {
                Section(t("波形", "Waveforms")) {
                    Text(t("第 1 张图只看三个关键时刻；后面 3 张图分别放大播放方波、BLE 环回、本地录音，便于看形状和相位。",
                           "The first chart shows only the three key arrival times; the next three charts zoom in on playback, BLE loopback, and local recording separately for waveform shape and phase."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LatencyEventTimelineView(markers: timelineMarkers)
                        .frame(height: 84)
                        .padding(.vertical, 4)
                    ForEach(runner.waveformTraces) { trace in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(traceTitle(trace.kind))
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                if let eventTimeMs = trace.eventTimeMs {
                                    Text("\(Int(eventTimeMs)) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            LatencyWaveformZoomView(
                                trace: trace,
                                color: traceColor(trace.kind)
                            )
                            .frame(height: 88)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section(t("操作", "Actions")) {
                if runner.isRunning {
                    Button(t("停止测试", "Stop Test"), role: .destructive) {
                        runner.stopTest()
                    }
                } else {
                    Button(t("开始延迟测试", "Start Latency Test")) {
                        runner.startTest()
                    }
                    .disabled(!ble.isReady)
                }

                if runner.isContinuousRunning {
                    Button(t("停止", "Stop"), role: .destructive) {
                        runner.stopContinuousTest()
                    }
                } else {
                    Button(t("持续通话测试", "Continuous Call Test")) {
                        runner.startContinuousTest()
                    }
                    .disabled(!ble.isReady || runner.isRunning)
                }
            }

            if runner.isContinuousRunning || !continuousAnalyzer.lastWaveformSamples.isEmpty {
                Section(t("实时频率与波形", "Live Frequency & Waveform")) {
                    if let hz = continuousAnalyzer.currentFrequencyHz {
                        HStack {
                            Text(t("检测频率", "Detected frequency"))
                            Spacer()
                            Text(String(format: "%.0f Hz", hz))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                    }
                    if !continuousAnalyzer.lastWaveformSamples.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("本地录音波形", "Local recording waveform"))
                                .font(.subheadline.weight(.medium))
                            ContinuousWaveformView(samples: continuousAnalyzer.lastWaveformSamples)
                                .frame(height: 88)
                        }
                    }
                    if !continuousAnalyzer.lastSpectrumMagnitudes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("幅度谱 (0–1 kHz)", "Magnitude spectrum (0–1 kHz)"))
                                .font(.subheadline.weight(.medium))
                            ContinuousSpectrumView(magnitudes: continuousAnalyzer.lastSpectrumMagnitudes)
                                .frame(height: 64)
                        }
                    }
                }
            }

            if !ble.isReady {
                Section {
                    Text(t("请先连接 BLE 设备。", "Connect BLE device first."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(t("延迟测试", "Latency Test"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LatencyTimelineMarker: Identifiable {
    let id: String
    let title: String
    let timeMs: Double
    let color: Color
}

private struct LatencyEventTimelineView: View {
    let markers: [LatencyTimelineMarker]

    private var maxTimeMs: Double {
        let markerMax = markers.map(\.timeMs).max() ?? 0
        return max(12, markerMax + 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(markers) { marker in
                HStack(spacing: 8) {
                    Circle()
                        .fill(marker.color)
                        .frame(width: 8, height: 8)
                    Text("\(marker.title): \(Int(marker.timeMs)) ms")
                        .font(.caption)
                }
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.08))
                    Path { path in
                        let y = proxy.size.height / 2
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                    ForEach(markers) { marker in
                        let x = width * CGFloat(marker.timeMs / maxTimeMs)
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        }
                        .stroke(marker.color.opacity(0.65), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        Circle()
                            .fill(marker.color)
                            .frame(width: 10, height: 10)
                            .position(x: x, y: proxy.size.height / 2)
                    }
                }
            }
            HStack {
                Text("0 ms")
                Spacer()
                Text("\(Int(maxTimeMs / 2)) ms")
                Spacer()
                Text("\(Int(maxTimeMs)) ms")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

private struct LatencyWaveformZoomView: View {
    let trace: LatencyWaveformTrace
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let sampleCount = max(trace.samples.count, 2)
            let maxTimeMs = Double(sampleCount - 1) * 1000 / trace.sampleRate
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))
                Path { path in
                    let midY = size.height / 2
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: size.width, y: midY))
                }
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                let eventX = trace.eventTimeMs.flatMap { eventTimeMs in
                    let relative = eventTimeMs - trace.startTimeMs
                    return relative >= 0 && maxTimeMs > 0 ? size.width * CGFloat(relative / maxTimeMs) : nil
                }
                if let eventX {
                    Path { path in
                        path.move(to: CGPoint(x: eventX, y: 0))
                        path.addLine(to: CGPoint(x: eventX, y: size.height))
                    }
                    .stroke(color.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }
                if trace.samples.count >= 2 {
                    Path { path in
                        for (index, sample) in trace.samples.enumerated() {
                            let x = size.width * CGFloat(Double(index) / Double(sampleCount - 1))
                            let y = size.height * (0.5 - CGFloat(sample) * 0.40)
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Continuous test: live waveform and spectrum

private struct ContinuousWaveformView: View {
    let samples: [Float]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let count = max(samples.count, 2)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))
                Path { path in
                    let midY = size.height / 2
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: size.width, y: midY))
                }
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                if samples.count >= 2 {
                    Path { path in
                        for (index, sample) in samples.enumerated() {
                            let x = size.width * CGFloat(Double(index) / Double(count - 1))
                            let y = size.height * (0.5 - CGFloat(sample) * 0.40)
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ContinuousSpectrumView: View {
    let magnitudes: [Float]

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let count = max(magnitudes.count, 1)
            let barWidth = max(1, (w - CGFloat(count - 1) * 2) / CGFloat(count))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))
                if !magnitudes.isEmpty {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<magnitudes.count, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.orange.opacity(0.5 + 0.5 * Double(magnitudes[i])))
                                .frame(width: barWidth, height: max(2, h * CGFloat(magnitudes[i])))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
