import SwiftUI
import AVFoundation

struct VoiceToneSelectionSheet: View {
    /// 为 `false` 时隐藏「我的声音」标题/卡片与「克隆我的声音」按钮；克隆与同步相关逻辑仍执行。
    private static let showMyVoiceCloneSectionUI = true

    private struct VoiceListItem: Identifiable, Equatable {
        let id: String
        let name: String
        let subtitle: String
        let isCloneVoice: Bool
        let cloneState: String?
    }
    
    private enum CloneFlowStep {
        case guide
        case reader
    }

    let language: Language
    let voices: [TTSVoice]
    @Binding var selectedVoiceId: String
    @Binding var selectedToneRaw: String
    @Binding var selectedVoiceDisplayName: String
    let onClose: () -> Void

    @State private var selectedItemId: String = ""
    @State private var showCloneSheet = false
    @State private var cloneFlowStep: CloneFlowStep = .guide
    @State private var isRecording = false
    @State private var cloneVoiceCancelling = false
    @State private var customVoices: [VoiceListItem] = []
    @State private var playingItemId: String?
    @State private var demoPlayer: AVPlayer?
    @State private var demoEndObserver: NSObjectProtocol?
    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var cloneSheetDetent: PresentationDetent = .height(388)
    @State private var isSubmittingClone = false
    @State private var cloneTrainingProgress: Double = 0
    @State private var cloneTrainingSuccess: Bool? = nil
    @State private var cloneStatusText: String?
    @State private var cloneUploadTask: Task<Void, Never>?
    @State private var cloneDemoAudioURL: String?
    @State private var cloneCanTrain = true
    @State private var recorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var showUnknownCloneAlert = false
    @ObservedObject private var ble = CallMateBLEClient.shared

    @Environment(\.colorScheme) private var colorScheme
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var voicePageBackground: Color { AppColors.backgroundPage }
    private var voiceCardBackground: Color { AppColors.backgroundCard }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        if Self.showMyVoiceCloneSectionUI {
                            VStack(alignment: .leading, spacing: 0) {
                                sectionHeader(t("我的声音", "My Voice"))
                                if customVoices.isEmpty {
                                    myVoiceEmptyCard
                                } else {
                                    VStack(spacing: 0) {
                                        ForEach(customVoices) { item in
                                            voiceRow(item)
                                            if item.id != customVoices.last?.id {
                                                voiceRowDivider
                                            }
                                        }
                                    }
                                    .background(voiceCardBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
                                    .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            sectionHeader(t("系统音色", "System Voices"))
                            VStack(spacing: 0) {
                                ForEach(systemVoiceItems) { item in
                                    voiceRow(item)
                                    if item.id != systemVoiceItems.last?.id {
                                        voiceRowDivider
                                    }
                                }
                            }
                            .background(voiceCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
                            .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(
                        .bottom,
                        Self.showMyVoiceCloneSectionUI ? (customVoices.isEmpty ? 40 : 100) : 40
                    )
                }

                if Self.showMyVoiceCloneSectionUI, !customVoices.isEmpty {
                    Button {
                        cloneFlowStep = .guide
                        showCloneSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "mic.fill")
                            Text(t("克隆我的声音", "Clone My Voice"))
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(AppColors.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: AppColors.primary.opacity(0.25), radius: 10, x: 0, y: 8)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
            .background(voicePageBackground)
            .navigationTitle(t("声音", "Voice"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: closeSheet) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                    }
                }
            }
            .onAppear {
                bootstrapSelection()
                Task {
                    await loadBoundCloneVoiceIfNeeded()
                    await refreshCloneStatusForCloneEntry()
                }
            }
            .onChange(of: selectedVoiceId) { _, _ in
                bootstrapSelectionIfNeeded()
            }
            .onChange(of: selectedToneRaw) { _, _ in
                bootstrapSelectionIfNeeded()
            }
            .onDisappear {
                stopPreviewPlayback()
                stopRecorder(discard: true)
                cloneUploadTask?.cancel()
            }
        }
        .sheet(isPresented: $showCloneSheet, onDismiss: {
            isRecording = false
            stopRecorder(discard: true)
            cloneUploadTask?.cancel()
        }) {
            ZStack {
                Color.clear.ignoresSafeArea()
                cloneFlowContent
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .presentationBackground(.ultraThinMaterial)
            .presentationDetents([.height(388), .height(580)], selection: $cloneSheetDetent)
            .presentationDragIndicator(.visible)
        }
        .onChange(of: showCloneSheet) { _, isPresented in
            guard isPresented else {
                cloneSheetDetent = .height(388)
                return
            }
            cloneUploadTask?.cancel()
            cloneUploadTask = Task { @MainActor in
                await refreshCloneStatusForCloneEntry()
            }
        }
        .onChange(of: isRecording) { _, recording in
            withAnimation(.easeInOut(duration: 0.3)) {
                cloneSheetDetent = recording ? .height(580) : .height(388)
            }
        }
        .onChange(of: isSubmittingClone) { _, submitting in
            if !submitting {
                withAnimation(.easeInOut(duration: 0.3)) {
                    cloneSheetDetent = .height(388)
                }
            }
        }
        .alert(t("该音色不可用", "Voice unavailable"), isPresented: $showUnknownCloneAlert) {
            Button(t("知道了", "OK"), role: .cancel) {}
        } message: {
            Text(t("请重新训练", "Please retrain"))
        }
    }
    
    @ViewBuilder
    private var cloneFlowContent: some View {
        switch cloneFlowStep {
        case .guide:
            cloneGuideCard
        case .reader:
            scriptReaderCard
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
            .padding(.leading, 16)
            .padding(.bottom, 8)
    }

    private var myVoiceEmptyCard: some View {
        VStack(spacing: 0) {
            Image(systemName: "mic")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                .frame(width: 56, height: 56)
                .background(Color(lightHex: "F9FAFB", darkHex: "1F2937").opacity(0.5))
                .clipShape(Circle())
                .padding(.bottom, 12)

            Text(t("暂无克隆声音", "No cloned voice yet"))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .padding(.bottom, 4)

            Text(t("创建专属你的AI分身声音，让沟通更具个性", "Create your AI voice for more personal conversations"))
                .font(.system(size: 13))
                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                .multilineTextAlignment(.center)
                .padding(.bottom, 20)

            Button {
                cloneFlowStep = .guide
                showCloneSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                    Text(t("克隆我的声音", "Clone My Voice"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Color(lightHex: "007AFF", darkHex: "0A84FF"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(lightHex: "007AFF", darkHex: "0A84FF").opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(voiceCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
    }

    private var voiceRowDivider: some View {
        Rectangle()
            .fill(Color(lightHex: "F3F4F6", darkHex: "1F2937").opacity(colorScheme == .dark ? 0.6 : 1))
            .frame(height: 0.5)
    }

    private static func avatarImageName(forVoiceId id: String, voiceName name: String) -> String? {
        let idLower = id.lowercased()
        if idLower.contains("taiwan") || idLower.contains("wanwan") || name == "湾湾小何" { return "VoiceAvatarBoy" }
        if idLower == "girl" || name == "邻家女孩" { return "VoiceAvatarGirl" }
        if idLower.contains("ceo") || idLower == "boss" || name == "霸道总裁" { return "VoiceAvatarBoss" }
        if idLower.contains("vivi") || name.contains("vivi") || name.contains("Vivi") { return "VoiceAvatarVivi" }
        return nil
    }

    private var systemVoiceItems: [VoiceListItem] {
        voices.map { voice in
            VoiceListItem(
                id: voice.id,
                name: voice.name,
                subtitle: t("在线音色", "Online Voice"),
                isCloneVoice: false,
                cloneState: nil
            )
        }
    }

    private var allItems: [VoiceListItem] {
        var merged: [VoiceListItem] = []
        for item in customVoices + systemVoiceItems {
            if !merged.contains(where: { $0.id == item.id }) {
                merged.append(item)
            }
        }
        return merged
    }

    private var selectedItem: VoiceListItem? {
        allItems.first(where: { $0.id == selectedItemId })
    }

    private var selectedScriptText: String {
        t(
            "福字要倒着贴，寓意福到，希望所有人新的一年福气满满，开开心心的。",
            "Read naturally: Wishing everyone happiness and good luck in the new year."
        )
    }

    private func voiceRow(_ item: VoiceListItem) -> some View {
        let disabled = isVoiceItemDisabled(item)
        let isSelected = selectedItemId == item.id
        let avatarName = item.isCloneVoice ? nil : Self.avatarImageName(forVoiceId: item.id, voiceName: item.name)
        return HStack(spacing: 16) {
            Group {
                if let name = avatarName {
                    Image(name)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color(lightHex: "F3F4F6", darkHex: "1F2937"), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
                } else {
                    Circle()
                        .fill(item.isCloneVoice ? AppColors.primary.opacity(0.15) : Color(lightHex: "F9FAFB", darkHex: "1F2937"))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: item.isCloneVoice ? "waveform" : "person.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(item.isCloneVoice ? AppColors.primary : AppColors.textTertiary)
                        )
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? Color(lightHex: "007AFF", darkHex: "0A84FF") : AppColors.textPrimary)
                Text(item.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
            }

            Spacer(minLength: 0)

            Group {
                if disabled {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                        .font(.system(size: 16, weight: .semibold))
                } else {
                    Button {
                        togglePreviewPlayback(for: item)
                    } label: {
                        if playingItemId == item.id {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Color(lightHex: "007AFF", darkHex: "0A84FF"))
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(isSelected ? Color(lightHex: "007AFF", darkHex: "0A84FF") : Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 32, height: 32)
            .padding(.trailing, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color(lightHex: "007AFF", darkHex: "0A84FF").opacity(colorScheme == .dark ? 0.1 : 0.05) : Color.clear)
        .contentShape(Rectangle())
        .opacity(disabled ? 0.45 : 1)
        .onTapGesture {
            guard !disabled else {
                print("[VoiceClone] tap ignored for disabled item id=\(item.id) state=\(item.cloneState ?? "nil")")
                showUnknownCloneAlert = true
                return
            }
            select(item)
        }
    }

    private var cloneGuideCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title + Close
            ZStack(alignment: .trailing) {
                Text(t("克隆我的声音", "Clone My Voice"))
                    .font(.system(size: 20, weight: .bold))
                    .frame(maxWidth: .infinity)
                Button {
                    showCloneSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppColors.textTertiary)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 24)

            // Tips
            VStack(alignment: .leading, spacing: 18) {
                tipRow(icon: "mic.fill", title: t("录制自己的声音", "Record your own voice"), subtitle: t("若使用他人声音，请确认已获取他人授权", "If using others' voices, obtain authorization first"))
                tipRow(icon: "house.fill", title: t("找一处安静的地方", "Find a quiet place"), subtitle: t("按照个人语气和说话习惯，自然流畅地朗读", "Read naturally with your own speaking style"))
                tipRow(icon: "list.bullet.rectangle", title: t("严格按照文本朗读", "Follow the script strictly"), subtitle: t("请注意严格按照下面文本朗读", "Please read exactly as prompted"))
            }
            .padding(.bottom, 36)

            if !cloneCanTrain {
                Text(t("该音色训练次数已用完（最多15次）", "Training attempts exhausted for this voice (max 15)"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .padding(.bottom, 12)
            }

            // CTA
            Button {
                guard cloneCanTrain else {
                    cloneStatusText = t("该音色已无可用训练次数", "No training attempts left for this voice")
                    return
                }
                cloneFlowStep = .reader
            } label: {
                Text(t("确认录制", "Confirm Recording"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "007AFF"))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color(hex: "007AFF").opacity(0.25), radius: 10, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .disabled(!cloneCanTrain)
            .opacity(cloneCanTrain ? 1 : 0.55)
        }
        .padding(.top, 40)
        .padding(.horizontal, 20)
        .padding(.bottom, 52)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func tipRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 32, height: 44)
                .foregroundStyle(Color(hex: "007AFF"))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
    }

    private var cloneHintIsError: Bool {
        if let text = cloneStatusText, !text.isEmpty { return true }
        return false
    }

    private var cloneHintText: String {
        if let text = cloneStatusText, !text.isEmpty { return text }
        return t("建议在安静环境录制", "Record in a quiet place")
    }

    private var scriptReaderCard: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if isRecording {
                    Spacer(minLength: 0)
                }

                // Header
                if !isRecording {
                    ZStack(alignment: .trailing) {
                        VStack(spacing: 2) {
                            Text(t("声音克隆", "Voice Clone"))
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(AppColors.textPrimary)
                            Text(t("请朗读以下文字", "Please read the text below"))
                                .font(.system(size: 13))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        Button {
                            showCloneSheet = false
                            isRecording = false
                            cloneVoiceCancelling = false
                            stopRecorder(discard: true)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AppColors.textTertiary)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 24)
                }

                // Script text card
                Text(selectedScriptText)
                    .font(.system(size: 18, weight: .regular))
                    .lineSpacing(8)
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.6))
                            )
                            .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
                    )
                    .padding(.bottom, 16)

                if !isSubmittingClone && !isRecording {
                    // Hint (shows error in red or default in orange)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(cloneHintIsError ? Color.red : Color(hex: "FF9500"))
                            .frame(width: 6, height: 6)
                        Text(cloneHintText)
                            .font(.system(size: 13))
                            .foregroundStyle(cloneHintIsError ? Color.red : Color(hex: "FF9500"))
                    }
                    .padding(.bottom, 24)
                }

                // Record button / Submitting state
                if isSubmittingClone {
                    cloneTrainingProgressView
                } else if !isRecording {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text(t("按住录制", "Hold to Record"))
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "007AFF"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Color(hex: "007AFF").opacity(0.25), radius: 10, x: 0, y: 8)
                    .allowsHitTesting(cloneCanTrain)
                }

                if isRecording {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, isRecording ? 0 : 32)
            .animation(.easeInOut(duration: 0.3), value: isRecording)

            // Recording overlay
            if isRecording {
                VoiceRecordingOverlay(language: language, isCancelling: cloneVoiceCancelling)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, alignment: isRecording ? .center : .top)
        .contentShape(Rectangle())
        .gesture(cloneHoldGesture)
        .allowsHitTesting(!isSubmittingClone)
    }

    private var cloneHoldGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isRecording {
                    isRecording = true
                    cloneVoiceCancelling = false
                    startRecording()
                } else {
                    cloneVoiceCancelling = value.translation.height < -60
                }
            }
            .onEnded { value in
                guard isRecording else { return }
                let cancelled = cloneVoiceCancelling || value.translation.height < -60
                isRecording = false
                cloneVoiceCancelling = false
                if cancelled {
                    stopRecorder(discard: true)
                } else {
                    stopRecordingAndSubmit()
                }
            }
    }

    private var cloneTrainingProgressView: some View {
        VStack(spacing: 14) {
            if cloneTrainingSuccess == true {
                ZStack {
                    Circle()
                        .fill(AppColors.success.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AppColors.success)
                }
                Text(t("训练完成，已切换到我的声音", "Training complete, switched to My Voice"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.success)
                    .multilineTextAlignment(.center)
            } else if cloneTrainingSuccess == false {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(AppColors.error)
                if let cloneStatusText, !cloneStatusText.isEmpty {
                    Text(cloneStatusText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppColors.error)
                        .multilineTextAlignment(.center)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: "007AFF"))
                        .symbolEffect(.variableColor.iterative, options: .repeating, value: isSubmittingClone)
                    Text(t("声音训练中，请稍候…", "Training voice, please wait…"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppColors.textPrimary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: "E5E7EB"))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "007AFF"), Color(hex: "34AAFF")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * cloneTrainingProgress), height: 6)
                    }
                }
                .frame(height: 6)

                Text("\(Int(cloneTrainingProgress * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.6))
                )
                .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        )
        .animation(.easeInOut(duration: 0.3), value: cloneTrainingSuccess)
    }

    private func select(_ item: VoiceListItem) {
        guard !isVoiceItemDisabled(item) else {
            print("[VoiceClone] select ignored for disabled item id=\(item.id) state=\(item.cloneState ?? "nil")")
            return
        }
        selectedItemId = item.id
        UserDefaults.standard.set(true, forKey: "callmate.userManuallySelectedVoice")

        if item.isCloneVoice {
            selectedVoiceDisplayName = item.name
            selectedVoiceId = item.id
            triggerFillerPreloadIfPossible(voiceId: item.id)
            return
        }

        selectedVoiceDisplayName = ""
        selectedVoiceId = item.id
        triggerFillerPreloadIfPossible(voiceId: item.id)
    }

    /// Fire-and-forget: after a voice is selected, push the 6 fillers down to
    /// the MCU so in-call `{type:"filler"}` from the server becomes a single
    /// BLE ctrl forward. Safe to call redundantly — the coordinator de-dups by
    /// meta hash. Skipped if BLE or preload char is not ready (legacy firmware).
    private func triggerFillerPreloadIfPossible(voiceId: String) {
        guard let deviceId = runtimeMCUDeviceID() else {
            print("[VoiceClone] skip preload: no MCU device id")
            return
        }
        guard CallMateBLEClient.shared.isPreloadReady else {
            print("[VoiceClone] skip preload: preload characteristic unavailable (legacy firmware?)")
            return
        }
        print("[VoiceClone] trigger filler preload voice=\(voiceId) device=\(deviceId)")
        _ = TTSFillerSyncCoordinator.shared.preload(voiceId: voiceId, deviceId: deviceId)
    }

    private func upsertCloneVoiceItem(speakerId: String, state: String?) {
        let name = t("我的声音", "My Voice")
        let status = (state ?? "").lowercased()
        let subtitle: String
        if status == "success" {
            subtitle = t("仅你可用", "Only available to you")
        } else if status == "training" {
            subtitle = t("训练中", "Training")
        } else if status == "failed" {
            subtitle = t("训练失败，可重试", "Training failed, retry")
        } else {
            subtitle = t("仅你可用", "Only available to you")
        }

        let item = VoiceListItem(id: speakerId, name: name, subtitle: subtitle, isCloneVoice: true, cloneState: state)
        if let idx = customVoices.firstIndex(where: { $0.id == speakerId }) {
            customVoices[idx] = item
        } else {
            customVoices.insert(item, at: 0)
        }
        normalizeSelectionIfNeeded()
    }

    private func isUnknownCloneState(_ state: String?) -> Bool {
        (state ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "unknown"
    }

    private func isVoiceItemDisabled(_ item: VoiceListItem) -> Bool {
        item.isCloneVoice && isUnknownCloneState(item.cloneState)
    }

    private func normalizeSelectionIfNeeded() {
        guard let current = selectedItem else { return }
        guard isVoiceItemDisabled(current) else { return }

        if let fallback = allItems.first(where: { !isVoiceItemDisabled($0) }) {
            selectedItemId = fallback.id
            if fallback.isCloneVoice {
                selectedVoiceDisplayName = fallback.name
                selectedVoiceId = fallback.id
            } else {
                selectedVoiceDisplayName = ""
                selectedVoiceId = fallback.id
            }
            print("[VoiceClone] selection normalized from disabled id=\(current.id) to id=\(fallback.id)")
        }
    }

    private func bootstrapSelection() {
        if !selectedVoiceDisplayName.isEmpty {
            if let mine = customVoices.first(where: { $0.name == selectedVoiceDisplayName }) {
                selectedItemId = mine.id
            }
            return
        }

        if !selectedVoiceId.isEmpty, allItems.contains(where: { $0.id == selectedVoiceId }) {
            selectedItemId = selectedVoiceId
            return
        }

        if !selectedVoiceId.isEmpty, !systemVoiceItems.contains(where: { $0.id == selectedVoiceId }) {
            let mine = VoiceListItem(
                id: selectedVoiceId,
                name: selectedVoiceDisplayName.isEmpty ? t("我的声音", "My Voice") : selectedVoiceDisplayName,
                subtitle: t("仅你可用", "Only available to you"),
                isCloneVoice: true,
                cloneState: nil
            )
            customVoices = [mine]
            selectedItemId = mine.id
            return
        }

        if let firstSystem = systemVoiceItems.first {
            selectedItemId = firstSystem.id
            selectedVoiceId = firstSystem.id
        }
    }

    private func bootstrapSelectionIfNeeded() {
        if selectedItem == nil {
            bootstrapSelection()
        }
    }

    private func closeSheet() {
        stopPreviewPlayback()
        onClose()
    }

    private func togglePreviewPlayback(for item: VoiceListItem) {
        if playingItemId == item.id {
            stopPreviewPlayback()
            return
        }

        stopPreviewPlayback()
        do {
            // Use media playback channel so volume follows media volume and is not muted by silent/DND notification policy.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            print("[Settings] audio session setup failed: \(error.localizedDescription)")
        }

        playRemotePreview(for: item)
    }

    private func playBuiltinPreview(for item: VoiceListItem) {
        let utterance = AVSpeechUtterance(string: selectedScriptText)
        utterance.voice = AVSpeechSynthesisVoice(language: language == .zh ? "zh-CN" : "en-US")
        utterance.rate = Float(0.5)
        utterance.pitchMultiplier = Float(1.0)
        utterance.volume = 1.0

        playingItemId = item.id
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(utterance)

        let expectedDuration = max(2.0, min(8.0, Double(utterance.speechString.count) / 7.0))
        DispatchQueue.main.asyncAfter(deadline: .now() + expectedDuration) {
            if playingItemId == item.id {
                playingItemId = nil
            }
        }
    }

    private func playRemotePreview(for item: VoiceListItem) {
        if item.isCloneVoice {
            if let rawURL = cloneDemoAudioURL, !rawURL.isEmpty {
                playURLPreview(rawURL, for: item)
            } else {
                playBuiltinPreview(for: item)
            }
            return
        }
        guard let voice = voices.first(where: { $0.id == item.id }) else { return }
        guard let rawURL = voice.demoURL, !rawURL.isEmpty else {
            playBuiltinPreview(for: item)
            return
        }
        let encoded = rawURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawURL
        playURLPreview(encoded, for: item)
    }

    private func playURLPreview(_ rawURL: String, for item: VoiceListItem) {
        guard let url = URL(string: rawURL) else {
            print("[VoicePreview] invalid URL: \(rawURL)")
            return
        }
        print("[VoicePreview] playing url: \(url.absoluteString)")

        let player = AVPlayer(url: url)
        demoPlayer = player
        playingItemId = item.id
        player.play()

        if let observer = demoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            demoEndObserver = nil
        }
        if let currentItem = player.currentItem {
            demoEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main
            ) { _ in
                if playingItemId == item.id {
                    playingItemId = nil
                }
                demoPlayer?.pause()
                demoPlayer = nil
            }
        }
    }

    private func stopPreviewPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        demoPlayer?.pause()
        demoPlayer = nil
        playingItemId = nil
        if let observer = demoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            demoEndObserver = nil
        }
    }

    private func runtimeMCUDeviceID() -> String? {
        let trimmed = (ble.runtimeMCUDeviceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func runtimeBluetoothID() -> String {
        WebSocketService.shared.runtimeBluetoothID
    }

    private func requestMicPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func startRecording() {
        cloneStatusText = nil
        cloneUploadTask?.cancel()
        print("[VoiceClone] startRecording requested")
        cloneUploadTask = Task { @MainActor in
            guard await requestMicPermission() else {
                isRecording = false
                cloneStatusText = t("麦克风权限未开启", "Microphone permission denied")
                print("[VoiceClone] microphone permission denied")
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try session.setActive(true, options: [])

                let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice_clone_recording.m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder?.prepareToRecord()
                recorder?.record()
                recordingURL = url
                print("[VoiceClone] recording started url=\(url.path)")
            } catch {
                isRecording = false
                cloneStatusText = t("录音启动失败", "Failed to start recording")
                print("[VoiceClone] start record failed: \(error)")
            }
        }
    }

    private func stopRecorder(discard: Bool) {
        let url = recordingURL
        recorder?.stop()
        recorder = nil
        if discard {
            if let recordingURL {
                try? FileManager.default.removeItem(at: recordingURL)
                print("[VoiceClone] recording discarded url=\(recordingURL.path)")
            }
            recordingURL = nil
        } else if let url {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                print("[VoiceClone] recording finished url=\(url.path) bytes=\(size.intValue)")
            } else {
                print("[VoiceClone] recording finished url=\(url.path)")
            }
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func stopRecordingAndSubmit() {
        stopRecorder(discard: false)
        guard let audioURL = recordingURL else {
            cloneStatusText = t("未获取到录音文件", "No recording captured")
            print("[VoiceClone] stopRecordingAndSubmit failed: recordingURL nil")
            return
        }
        guard let duration = cloneAudioDuration(at: audioURL), duration >= 3.0 else {
            cloneStatusText = t("提交的语音不能低于3秒", "Voice sample must be at least 3 seconds")
            invalidateCurrentRecording()
            print("[VoiceClone] stopRecordingAndSubmit blocked: duration < 3s")
            return
        }
        guard cloneAudioHasAudibleSignal(at: audioURL) else {
            cloneStatusText = t("提交的语音必须要有声音", "Voice sample must contain audible sound")
            invalidateCurrentRecording()
            print("[VoiceClone] stopRecordingAndSubmit blocked: audio appears silent")
            return
        }
        cloneUploadTask?.cancel()
        print("[VoiceClone] submit training with audio=\(audioURL.path)")
        cloneUploadTask = Task { @MainActor in
            await submitCloneTraining(audioURL: audioURL)
        }
    }

    private func invalidateCurrentRecording() {
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }

    private func cloneAudioDuration(at url: URL) -> TimeInterval? {
        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.processingFormat.sampleRate
            guard sampleRate > 0 else { return nil }
            let seconds = Double(file.length) / sampleRate
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            print("[VoiceClone] duration check failed: \(error)")
            return nil
        }
    }

    private func cloneAudioHasAudibleSignal(at url: URL) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            let frameCapacity: AVAudioFrameCount = 4096
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCapacity
            ) else {
                return false
            }

            // Raise thresholds to reduce false positives from low-level noise.
            let rmsThreshold: Float = 0.008
            let peakThreshold: Float = 0.05

            while true {
                try file.read(into: buffer, frameCount: frameCapacity)
                let frames = Int(buffer.frameLength)
                if frames == 0 { break }

                let channels = Int(buffer.format.channelCount)
                var sumSquares: Float = 0
                var sampleCount: Int = 0
                var peak: Float = 0

                switch buffer.format.commonFormat {
                case .pcmFormatFloat32:
                    guard let channelData = buffer.floatChannelData else { continue }
                    for channel in 0..<channels {
                        let samples = channelData[channel]
                        for i in 0..<frames {
                            let value = abs(samples[i])
                            sumSquares += value * value
                            sampleCount += 1
                            if value > peak { peak = value }
                        }
                    }
                case .pcmFormatInt16:
                    guard let channelData = buffer.int16ChannelData else { continue }
                    for channel in 0..<channels {
                        let samples = channelData[channel]
                        for i in 0..<frames {
                            let raw = Float(abs(Int32(samples[i])))
                            let value = raw / Float(Int16.max)
                            sumSquares += value * value
                            sampleCount += 1
                            if value > peak { peak = value }
                        }
                    }
                case .pcmFormatInt32:
                    guard let channelData = buffer.int32ChannelData else { continue }
                    for channel in 0..<channels {
                        let samples = channelData[channel]
                        for i in 0..<frames {
                            let raw = Float(abs(samples[i]))
                            let value = raw / Float(Int32.max)
                            sumSquares += value * value
                            sampleCount += 1
                            if value > peak { peak = value }
                        }
                    }
                default:
                    return false
                }

                if sampleCount > 0 {
                    let rms = sqrt(sumSquares / Float(sampleCount))
                    if rms >= rmsThreshold || peak >= peakThreshold {
                        return true
                    }
                }
            }
        } catch {
            print("[VoiceClone] audio signal check failed: \(error)")
        }
        return false
    }

    private func loadBoundCloneVoiceIfNeeded() async {
        guard let token = await BackendAuthManager.shared.ensureToken(),
              BackendAuthManager.looksLikeJWT(token) else {
            print("[VoiceClone] loadBoundCloneVoiceIfNeeded skipped: token missing")
            return
        }
        do {
            let clone = try await queryDeviceClone(token: token)
            if let info = clone.data.voice_clone {
                upsertCloneVoiceItem(speakerId: info.speaker_id, state: info.state)
                if let demoAudio = info.demo_audio, !demoAudio.isEmpty {
                    cloneDemoAudioURL = demoAudio
                    print("[VoiceClone] bound clone demo_audio loaded")
                }
                print("[VoiceClone] bound clone loaded speaker_id=\(info.speaker_id) state=\(info.state ?? "nil")")
                if !isUnknownCloneState(info.state),
                   (selectedVoiceId == info.speaker_id || selectedVoiceDisplayName == t("我的声音", "My Voice")) {
                    selectedVoiceId = info.speaker_id
                    selectedVoiceDisplayName = t("我的声音", "My Voice")
                    selectedItemId = info.speaker_id
                    print("[VoiceClone] bound clone auto-selected speaker_id=\(info.speaker_id)")
                }
            } else {
                print("[VoiceClone] no bound clone voice on device")
            }
        } catch {
            print("[VoiceClone] load bound clone failed: \(error)")
        }
    }

    private func refreshCloneStatusForCloneEntry() async {
        cloneStatusText = nil
        guard let token = await BackendAuthManager.shared.ensureToken(),
              BackendAuthManager.looksLikeJWT(token) else {
            cloneCanTrain = true
            print("[VoiceClone] refreshCloneStatus skipped: token missing")
            return
        }

        do {
            let bound = try await queryDeviceClone(token: token)
            guard let info = bound.data.voice_clone else {
                cloneCanTrain = true
                print("[VoiceClone] refreshCloneStatus skipped: no bound voice clone")
                return
            }

            upsertCloneVoiceItem(speakerId: info.speaker_id, state: info.state)
            if let demoAudio = info.demo_audio, !demoAudio.isEmpty {
                cloneDemoAudioURL = demoAudio
            }

            guard let deviceId = runtimeMCUDeviceID() else {
                cloneCanTrain = false
                cloneStatusText = t("请先连接 EchoCard", "Please connect EchoCard first")
                print("[VoiceClone] refreshCloneStatus blocked: runtime MCU device-id missing")
                return
            }
            let status = try await queryCloneStatus(token: token, deviceId: deviceId, speakerId: info.speaker_id)
            upsertCloneVoiceItem(speakerId: status.data.speaker_id, state: status.data.state)
            if let demoAudio = status.data.demo_audio, !demoAudio.isEmpty {
                cloneDemoAudioURL = demoAudio
                print("[VoiceClone] refreshed latest demo_audio from status")
            }

            let canTrain = status.data.can_train ?? true
            cloneCanTrain = canTrain
            if !canTrain {
                cloneStatusText = t("该音色训练次数已用完（最多15次）", "Training attempts exhausted for this voice (max 15)")
            }
            print("[VoiceClone] refreshCloneStatus can_train=\(canTrain)")
        } catch {
            cloneCanTrain = true
            print("[VoiceClone] refreshCloneStatus failed: \(error)")
        }
    }

    private func submitCloneTraining(audioURL: URL) async {
        isSubmittingClone = true
        cloneTrainingProgress = 0.05
        cloneStatusText = nil
        defer { isSubmittingClone = false }
        print("[VoiceClone] submitCloneTraining begin")

        guard let token = await BackendAuthManager.shared.ensureToken(),
              BackendAuthManager.looksLikeJWT(token) else {
            cloneStatusText = t("获取 token 失败", "Failed to get token")
            print("[VoiceClone] submitCloneTraining failed: token missing")
            return
        }

        guard let deviceId = runtimeMCUDeviceID() else {
            cloneStatusText = t("请先连接 EchoCard", "Please connect EchoCard first")
            print("[VoiceClone] submitCloneTraining blocked: runtime MCU device-id missing")
            return
        }
        let bluetoothId = runtimeBluetoothID()
        print("[VoiceClone] submitCloneTraining device_id=\(deviceId) bluetooth_id=\(bluetoothId)")

        do {
            try await BackendAuthManager.shared.reportDevice(deviceId: deviceId, bluetoothId: bluetoothId, token: token)
            print("[VoiceClone] device report ok")
        } catch {
            // Keep trying training; report may fail transiently on some deployments.
            print("[VoiceClone] report device failed: \(error)")
        }

        do {
            let bound = try await queryDeviceClone(token: token)
            let speakerId = bound.data.voice_clone?.speaker_id ?? deviceId
            print("[VoiceClone] training speaker_id=\(speakerId)")
            let train = try await trainClone(token: token, deviceId: deviceId, speakerId: speakerId, text: selectedScriptText, audioURL: audioURL)
            upsertCloneVoiceItem(speakerId: train.data.speaker_id, state: train.data.state)
            withAnimation(.easeInOut(duration: 0.4)) { cloneTrainingProgress = 0.15 }
            print("[VoiceClone] train accepted speaker_id=\(train.data.speaker_id) state=\(train.data.state)")

            let status = try await pollCloneStatus(token: token, deviceId: deviceId, speakerId: train.data.speaker_id)
            cloneCanTrain = status.data.can_train ?? true
            if status.data.state?.lowercased() == "success" {
                upsertCloneVoiceItem(speakerId: status.data.speaker_id, state: status.data.state)
                if let demoAudio = status.data.demo_audio, !demoAudio.isEmpty {
                    cloneDemoAudioURL = demoAudio
                    print("[VoiceClone] training demo_audio saved")
                }
                selectedItemId = status.data.speaker_id
                selectedVoiceId = status.data.speaker_id
                selectedVoiceDisplayName = t("我的声音", "My Voice")
                UserDefaults.standard.set(true, forKey: "callmate.userManuallySelectedVoice")
                triggerFillerPreloadIfPossible(voiceId: status.data.speaker_id)
                withAnimation { cloneTrainingProgress = 1.0 }
                cloneTrainingSuccess = true
                print("[VoiceClone] training success speaker_id=\(status.data.speaker_id)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showCloneSheet = false
                cloneTrainingSuccess = nil
            } else {
                let reason = status.data.train_failed_reason ?? t("请稍后重试", "Please retry later")
                cloneTrainingSuccess = false
                cloneStatusText = t("训练失败：", "Training failed: ") + reason
                print("[VoiceClone] training terminal non-success state=\(status.data.state ?? "nil") reason=\(reason)")
            }
        } catch {
            cloneStatusText = t("训练请求失败", "Training request failed")
            print("[VoiceClone] submit failed: \(error)")
        }
    }

    private func queryDeviceClone(token: String) async throws -> DeviceVoiceCloneResponse {
        guard let deviceId = runtimeMCUDeviceID() else {
            throw NSError(
                domain: "VoiceClone",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "MCU device-id unavailable"]
            )
        }
        guard let url = URL(string: AppConfig.voiceApiBaseURL + "/api/device/\(deviceId)/voice-clone") else {
            throw URLError(.badURL)
        }
        print("[VoiceClone] queryDeviceClone GET \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        print("[VoiceClone] queryDeviceClone ok device_id=\(deviceId)")
        return try JSONDecoder().decode(DeviceVoiceCloneResponse.self, from: data)
    }

    private func trainClone(token: String, deviceId: String, speakerId: String, text: String, audioURL: URL) async throws -> VoiceCloneTrainResponse {
        guard let url = URL(string: AppConfig.voiceApiBaseURL + "/api/voice-clone/train") else {
            throw URLError(.badURL)
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("device_id", deviceId)
        appendField("speaker_id", speakerId)
        appendField("text", text)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"voice_clone.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if !(200...299).contains(http.statusCode) {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            print("[VoiceClone] trainClone http=\(http.statusCode) body=\(raw)")
            throw NSError(domain: "VoiceClone", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: raw])
        }
        print("[VoiceClone] trainClone ok speaker_id=\(speakerId) payload_bytes=\(audioData.count)")
        return try JSONDecoder().decode(VoiceCloneTrainResponse.self, from: data)
    }

    private func queryCloneStatus(token: String, deviceId: String, speakerId: String) async throws -> VoiceCloneStatusResponse {
        guard var components = URLComponents(string: AppConfig.voiceApiBaseURL + "/api/voice-clone/status") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "speaker_id", value: speakerId)
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        print("[VoiceClone] queryCloneStatus GET \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if !(200...299).contains(http.statusCode) {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            print("[VoiceClone] queryCloneStatus http=\(http.statusCode) body=\(raw)")
            throw NSError(domain: "VoiceClone", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: raw])
        }
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        print("[VoiceClone] queryCloneStatus full response http=\(http.statusCode) body=\(raw)")
        let decoded = try JSONDecoder().decode(VoiceCloneStatusResponse.self, from: data)
        print("[VoiceClone] status speaker_id=\(decoded.data.speaker_id) state=\(decoded.data.state ?? "nil")")
        return decoded
    }

    private func pollCloneStatus(token: String, deviceId: String, speakerId: String) async throws -> VoiceCloneStatusResponse {
        let maxAttempts = 20
        for attempt in 0..<maxAttempts {
            if Task.isCancelled { throw CancellationError() }
            let status = try await queryCloneStatus(token: token, deviceId: deviceId, speakerId: speakerId)
            let state = (status.data.state ?? "").lowercased()
            if state == "success" || state == "failed" || state == "expired" {
                print("[VoiceClone] poll terminal state=\(state) attempt=\(attempt + 1)")
                return status
            }
            withAnimation(.easeInOut(duration: 0.4)) {
                cloneTrainingProgress = Double(attempt + 1) / Double(maxAttempts)
            }
            print("[VoiceClone] poll in-progress state=\(state.isEmpty ? "nil" : state) attempt=\(attempt + 1)")
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        print("[VoiceClone] poll reached max attempts, final query")
        return try await queryCloneStatus(token: token, deviceId: deviceId, speakerId: speakerId)
    }
}
