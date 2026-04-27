import Foundation

// MARK: - AudioServiceDelegate

extension CallSessionController: AudioServiceDelegate {
    /// Invoked from `AVAudioEngine`'s tap on the CoreAudio realtime thread — MUST remain
    /// `nonisolated` and must not touch main-actor state. `inputSource` and `ws` are
    /// `nonisolated let` on `CallSessionController`; `ws.sendAudioData(_:)` is `nonisolated`
    /// on `WebSocketService` and is backed by a lock-protected pump. The whole uplink path
    /// from capture to `URLSessionWebSocketTask.send` therefore never hops the main actor.
    nonisolated func audioServiceDidCaptureOpusPacket(_ data: Data) {
        guard inputSource == .microphone else { return }
        ws.sendAudioData(data)
    }

    nonisolated func audioServiceDidFinishPlaying() {
        // no-op
    }
}
