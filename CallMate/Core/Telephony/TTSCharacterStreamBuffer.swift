//
//  TTSCharacterStreamBuffer.swift
//  CallMate
//
//  缓冲区算法：将逐句到达的 TTS 文本转为逐字输出。
//  speed = base_speed * (1 + buffer_len / K)
//  buffer 多 → 快速吐字；buffer 快空 → 慢慢输出。
//
//  设计原则：
//    - 缓冲器本身不向 SwiftUI 广播；通过回调把增量文本写入一个独立的
//      ObservableObject（TTSStreamingBubbleState），仅流式气泡订阅，避免页面级重绘。
//    - append()    新句子入队，自动启动流式任务
//    - markDone()  通知不再有新句子（tts_stop），
//                  任务排空后自动回调 onFinished
//    - reset()     立即终止并清空（tts_start / 新通话）
//

import Foundation
import Combine

@MainActor
final class TTSStreamingBubbleState: ObservableObject {
    @Published var text: String = ""
    /// true 时在气泡位置显示 loading 三点动画（等待 AI 首字）
    @Published var isLoading: Bool = false

    private var loadingTimeoutTask: Task<Void, Never>?

    /// 开始 loading；若 `timeout` 秒内未被 `stopLoading()` 取消，则自动隐藏三点动画。
    func startLoading(timeout: TimeInterval = 5) {
        isLoading = true
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isLoading = false
        }
    }

    /// 手动结束 loading，同时取消超时任务。
    func stopLoading() {
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = nil
        isLoading = false
    }
}

@MainActor
final class TTSCharacterStreamBuffer {
    // MARK: - Configuration
    let baseSpeedMs: Double
    let bufferSpeedK: Double

    // MARK: - State
    private var buffer: [Character] = []
    private var streamTask: Task<Void, Never>?
    private var isDone: Bool = false

    /// 每输出一个字符时回调，参数为当前已显示文本（驱动 TTSStreamingBubbleState.text）
    private let onDisplayUpdate: (String) -> Void
    /// buffer 排空且已标记 done 时回调，参数为最终完整文本
    private let onFinished: (String) -> Void

    private var displayedText: String = ""

    init(
        baseSpeedMs: Double = 240,
        bufferSpeedK: Double = 40,
        onDisplayUpdate: @escaping (String) -> Void,
        onFinished: @escaping (String) -> Void
    ) {
        self.baseSpeedMs = baseSpeedMs
        self.bufferSpeedK = bufferSpeedK
        self.onDisplayUpdate = onDisplayUpdate
        self.onFinished = onFinished
    }

    // MARK: - Public API

    /// 追加新句子到缓冲区，自动启动流式任务
    func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        buffer.append(contentsOf: trimmed)
        startStreamingIfNeeded()
    }

    /// 通知不再有新句子（对应 tts_stop）。
    /// 不打断当前流式输出，缓冲区排空后自动回调 onFinished。
    func markDone() {
        isDone = true
        if streamTask == nil && buffer.isEmpty {
            finalize()
        }
    }

    /// 立即终止并清空（tts_start / 新通话开始时调用）
    func reset() {
        streamTask?.cancel()
        streamTask = nil
        buffer.removeAll()
        displayedText = ""
        isDone = false
        onDisplayUpdate("")
    }

    /// 将未输出完的文字先提交到 onFinished，再重置缓冲区。
    /// 用于新的 tts_start 到来时：上一句话的文字不能被直接丢弃，
    /// 应当作为一条完整 AI 消息保留在会话气泡列表中。
    func flushAndReset() {
        streamTask?.cancel()
        streamTask = nil

        // 合并已显示文字 + 缓冲区中尚未输出的字符，得到完整句子
        let remaining = String(buffer)
        let full = displayedText + remaining

        buffer.removeAll()
        displayedText = ""
        isDone = false
        onDisplayUpdate("")

        let cleaned = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            onFinished(cleaned)
        }
    }

    var currentDisplayedText: String { displayedText }

    // MARK: - Private

    private func startStreamingIfNeeded() {
        guard streamTask == nil else { return }
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard !buffer.isEmpty else {
                    if isDone { finalize() }
                    break
                }
                let bufferLen = buffer.count
                // buffer 越多 → 除数越大 → delay 越短 → 输出越快（追赶积压）
                // buffer=0:  delay = baseSpeedMs（最慢，逐字感强）
                // buffer=K:  delay = baseSpeedMs / 2
                let delayMs = baseSpeedMs / (1.0 + Double(bufferLen) / bufferSpeedK)
                try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
                guard !Task.isCancelled else { break }
                if !buffer.isEmpty {
                    let char = buffer.removeFirst()
                    displayedText.append(char)
                    onDisplayUpdate(displayedText)
                }
            }
            if !Task.isCancelled {
                streamTask = nil
            }
        }
    }

    private func finalize() {
        let finalText = displayedText
        displayedText = ""
        isDone = false
        let cleaned = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            onFinished(cleaned)
        }
        onDisplayUpdate("")
    }
}
