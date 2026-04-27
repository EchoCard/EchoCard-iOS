//
//  CallRecordingPlayer.swift
//  CallMate
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class CallRecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isReady: Bool = false
    @Published private(set) var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var lastError: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) {
        stop()
        lastError = nil

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            duration = p.duration
            currentTime = 0
            isReady = true
        } catch {
            isReady = false
            lastError = error.localizedDescription
        }
    }

    func togglePlayPause() {
        guard isReady else { return }
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let player else { return }
        lastError = nil
        // 确保报告页回放一定能出声（不受静音开关影响）
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])
        try? session.setActive(true)
        if player.play() {
            isPlaying = true
            startTimer()
        } else {
            lastError = "Play failed"
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        isReady = false
        duration = 0
        currentTime = 0
        stopTimer()
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(seconds, player.duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stopTimer()
        currentTime = player.duration
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(timeInterval: 0.2, target: self, selector: #selector(handlePlaybackTimerTick), userInfo: nil, repeats: true)
    }

    @objc private func handlePlaybackTimerTick() {
        guard let player else { return }
        currentTime = player.currentTime
        duration = player.duration
        if !player.isPlaying {
            isPlaying = false
            stopTimer()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

