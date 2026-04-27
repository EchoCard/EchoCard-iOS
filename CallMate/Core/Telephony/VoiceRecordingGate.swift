//
//  VoiceRecordingGate.swift
//  CallMate
//
//  串行化"按住说话"录音控制器调用。UI 状态由手势同步驱动，
//  录音控制器（beginManualListen / endManualListen / cancelManualListen）
//  通过本 Gate 串行派发，UI 线程永远不会等它。
//
//  为什么需要：
//  - 快速按+松（或 USB 调试导致主循环慢），begin/end 回调可能
//    在同一帧内触发，如果控制器调用直接跟着 UI 事件同步执行，
//    begin 的副作用（权限弹窗、音频路由切换、BLE 指令等）会抢占
//    主线程并撞上 end，引发状态错乱（蓝色半圆 UI 卡死）。
//  - Gate 保证 begin→end 严格按到达顺序执行，后续 end 任务
//    会 await 前一个 begin 任务完成，再执行自己的 end。
//  - 忽略无对应 begin 的 end；忽略已 active 时的重复 begin。
//

import Foundation

@MainActor
final class VoiceRecordingGate {
    private enum State { case idle, active }

    private var state: State = .idle
    private var pendingTail: Task<Void, Never>? = nil

    /// 派发 begin。若当前已 active，直接忽略。
    /// - Parameter work: 在 MainActor 上执行的 begin 侧副作用（如 controller.beginManualListen）。
    func begin(work: @MainActor @escaping () async -> Void) {
        let previous = pendingTail
        pendingTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard self.state == .idle else { return }
            self.state = .active
            await work()
        }
    }

    /// 派发 end / cancel。若当前 idle（未 begin 过或 begin 被忽略），直接忽略。
    /// - Parameters:
    ///   - cancelled: 是否是"移出半圆取消"场景。
    ///   - work: 在 MainActor 上执行的 end 侧副作用（如 controller.endManualListen）。
    func end(cancelled: Bool, work: @MainActor @escaping (Bool) async -> Void) {
        let previous = pendingTail
        pendingTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard self.state == .active else { return }
            self.state = .idle
            await work(cancelled)
        }
    }

    /// 强制复位（例如视图消失、切后台），立即置 idle 并尝试取消 pending。
    func reset() {
        pendingTail?.cancel()
        pendingTail = nil
        state = .idle
    }
}
