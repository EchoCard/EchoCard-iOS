import Foundation

// MARK: - Tracing Helpers

extension CallSessionController {
    func traceReset(reason: String) {
        traceClock = TraceClock()
        traceSessionSeq &+= 1
        tBleFirstRxNs = nil
        tWsFirstUpSendNs = nil
        tWsFirstDownRxNs = nil
        tBleFirstUpSendNs = nil
        tTtsFirstEnqueueNs = nil
        print("[Trace] reset seq=\(traceSessionSeq) reason=\(reason)")
    }

    func traceMark(_ label: String, store: inout UInt64?) {
        if store != nil { return }
        let t = traceClock.nowNs()
        store = t
        print(String(format: "[Trace] %@ t=%.1fms seq=%llu", label, traceClock.msSinceT0(t), traceSessionSeq))
    }

    func traceLogDelta(_ label: String, _ a: UInt64?, _ b: UInt64?) {
        guard let a, let b else { return }
        print(String(format: "[Trace] %@ dt=%.1fms seq=%llu", label, traceClock.deltaMs(a, b), traceSessionSeq))
    }

    func nowLogString() -> String {
        Self.logDateFormatter.string(from: Date())
    }

    func latencyLog(_ event: String, uid: Int? = nil) {
        let now = Date()
        let uidText = uid ?? currentIncomingCall?.uid ?? pendingIncomingCall?.uid ?? aiAnswerRequestUID ?? -1
        let inMs = latIncomingAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let ansMs = latAnswerSentAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let actMs = latCallActiveAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let astMs = latAudioStartSentAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        print("[LAT][iOS] t=\(nowLogString()) uid=\(uidText) event=\(event) dt_in=\(inMs)ms dt_answer=\(ansMs)ms dt_active=\(actMs)ms dt_audio_start=\(astMs)ms")
    }

    func latencyWSLog(_ event: String, extra: String = "") {
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[LAT][WS] t=\(nowLogString()) event=\(event)\(suffix)")
    }

    func latencyManualSceneLog(_ event: String, extra: String = "") {
        guard scene.isManualInteractionScene else { return }
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[LAT][Manual] t=\(nowLogString()) scene=\(scene.rawValue) input=\(inputSource) seq=\(traceSessionSeq) event=\(event)\(suffix)")
    }
}
