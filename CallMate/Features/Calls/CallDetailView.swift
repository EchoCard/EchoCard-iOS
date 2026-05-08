//
//  CallDetailView.swift
//  CallMate
//

import SwiftUI
import SwiftData

struct CallDetailView: View {
    let call: CallLog
    let language: Language
    let isTest: Bool
    let onBack: () -> Void
    
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    
    @Environment(\.modelContext) private var modelContext
    @Query private var allCalls: [CallLog]

    @State private var selectedFeedbackType: String?
    @StateObject private var feedbackVoiceControl = FeedbackVoiceControl()
    @StateObject private var recordingPlayer = CallRecordingPlayer()
    @State private var currentTime = 0
    @State private var sliderTime: Double = 0
    @State private var isScrubbing: Bool = false
    @State private var hasStartedPlayback: Bool = false
    @State private var isVoiceCancelling = false
    @State private var voiceHintActive = false
    @State private var shouldAutoScrollToFeedback = false
    @State private var shouldAutoPlayFeedbackIntro = false
    @State private var feedbackMessageCount = 0
    @State private var screenFrameInGlobal: CGRect = .zero

    private let feedbackChatAnchor = "feedbackChatAnchor"
    private let feedbackChatBottomAnchor = "feedbackChatBottomAnchor"
    
    private var totalDuration: Int {
        if recordingPlayer.duration > 0 {
            return Int(ceil(recordingPlayer.duration))
        }
        return max(0, call.durationSeconds)
    }
    private var transcriptLines: [TranscriptLine] {
        call.transcript.sorted(by: { $0.index < $1.index })
    }
    
    /// 是否有可回拨的号码（模拟通话等无号码时不显示回拨按钮）
    private var hasDialablePhone: Bool {
        let allowed = CharacterSet(charactersIn: "0123456789+*#")
        let trimmed = String(call.phone.unicodeScalars.filter { allowed.contains($0) })
        return !trimmed.isEmpty
    }

    private var repeatCallCount: Int {
        allCalls.filter { !$0.isSimulation && !$0.isOutboundCall && $0.phone == call.phone }.count
    }

    private var strangerRepeatTagText: String? {
        guard !isTest else { return nil }
        if repeatCallCount == 2 { return t("多次", "Multiple") }
        if repeatCallCount > 2 { return t("多次", "Multiple") }
        return nil
    }

    private var repeatTagColor: Color {
        repeatCallCount > 2 ? AppColors.error : AppColors.primary
    }

    private var trimmedLabel: String {
        call.label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isPlaceholderLabel: Bool {
        let lowered = trimmedLabel.lowercased()
        return trimmedLabel.isEmpty
            || lowered.contains("未知")
            || lowered.contains("unknown")
            || lowered.contains("陌生号码")
            || lowered.contains("未识别")
    }

    private var detailNavigationTitle: String {
        if isTest { return t("测试报告", "Test Report") }
        let trimmedPhone = call.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPhone.isEmpty { return trimmedPhone }
        if call.isOutboundCall { return t("外呼电话", "Outbound Call") }
        return isPlaceholderLabel ? t("未知来电", "Unknown Caller") : trimmedLabel
    }

    private var detailDisplayName: String {
        if call.isOutboundCall {
            return isPlaceholderLabel ? t("外呼电话", "Outbound Call") : trimmedLabel
        }
        if !trimmedLabel.isEmpty { return trimmedLabel }
        let trimmedPhone = call.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPhone.isEmpty ? t("未知来电", "Unknown Caller") : trimmedPhone
    }

    private enum CallerCategory {
        case personalContact
        case courier
        case rider
        case carrier
        case bank
        case marketing
        case uncategorized
    }

    private var callerCategory: CallerCategory {
        let label = trimmedLabel
        if label.isEmpty { return .uncategorized }

        let lowered = label.lowercased()
        if lowered.contains("未知") || lowered.contains("unknown") || lowered.contains("陌生号码") || lowered.contains("未识别") {
            return .uncategorized
        }

        let riderKeywords = ["外卖", "骑手", "美团", "饿了么"]
        if riderKeywords.contains(where: { lowered.contains($0) }) { return .rider }

        let courierKeywords = ["快递", "驿站", "派件", "顺丰", "圆通", "中通", "韵达", "申通",
                               "极兔", "菜鸟", "courier", "express", "delivery"]
        if courierKeywords.contains(where: { lowered.contains($0) }) { return .courier }

        let carrierKeywords = ["移动", "联通", "电信", "10086", "10010", "10000",
                               "china mobile", "china unicom", "china telecom"]
        if carrierKeywords.contains(where: { lowered.contains($0) }) { return .carrier }

        let bankKeywords = ["银行", "保险", "贷款", "理财", "信用卡", "催收",
                            "bank", "insurance", "loan", "finance"]
        if bankKeywords.contains(where: { lowered.contains($0) }) { return .bank }

        let marketingKeywords = ["推广", "推销", "广告", "营销", "marketing"]
        if marketingKeywords.contains(where: { lowered.contains($0) }) { return .marketing }

        let digitsOnly = label.unicodeScalars.allSatisfy {
            CharacterSet.decimalDigits.contains($0) || $0 == "+" || $0 == "-" || $0 == " "
        }
        if digitsOnly { return .uncategorized }

        return .personalContact
    }

    private var categoryColor: Color {
        switch callerCategory {
        case .personalContact: return Color(hex: "007AFF")
        case .courier:         return Color(hex: "34C759")
        case .rider:           return Color(hex: "FF9500")
        case .carrier:         return Color(hex: "5856D6")
        case .bank:            return Color(hex: "5AC8FA")
        case .marketing:       return Color(hex: "A2845E")
        case .uncategorized:   return Color(hex: "8E8E93")
        }
    }

    private var headerCategoryText: String {
        if call.isOutboundCall {
            if !isPlaceholderLabel { return trimmedLabel }
            let trimmedPhone = call.phone.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedPhone.isEmpty ? t("外呼电话", "Outbound Call") : trimmedPhone
        }
        if callerCategory == .uncategorized {
            let trimmedPhone = call.phone.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedPhone.isEmpty ? t("通话详情", "Call Detail") : trimmedPhone
        }
        return trimmedLabel
    }

    private var callDirectionIconName: String {
        call.isOutboundCall ? "arrow.up.right" : "arrow.down.left"
    }

    @ViewBuilder
    private var headerMetaRow: some View {
        HStack(spacing: 6) {
            Text(headerCategoryText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(categoryColor)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(categoryColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Image(systemName: callDirectionIconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)

            if let tag = strangerRepeatTagText {
                Text(tag)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: "FF9500"))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(hex: "FF9500").opacity(0.10))
                    .clipShape(Capsule())
            }
        }
    }

    private var detailBackground: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(hex: "F6F8FF"), location: 0),
                    .init(color: Color(hex: "F3F5FF"), location: 0.4),
                    .init(color: Color(hex: "F5F4FF"), location: 0.7),
                    .init(color: Color(hex: "F4F7FF"), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(colors: [Color(hex: "DCE8FF").opacity(0.5), .clear], center: UnitPoint(x: 0.2, y: 0.1), startRadius: 0, endRadius: 400)
            RadialGradient(colors: [Color(hex: "E6E1FA").opacity(0.35), .clear], center: UnitPoint(x: 0.85, y: 0.6), startRadius: 0, endRadius: 350)
            RadialGradient(colors: [Color(hex: "D7E6FF").opacity(0.3), .clear], center: UnitPoint(x: 0.4, y: 0.9), startRadius: 0, endRadius: 300)
        }
    }

    private var analysisTimestampText: String {
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: language == .zh ? "zh_CN" : "en_US")
        timeFormatter.dateFormat = "HH:mm"
        let time = timeFormatter.string(from: call.startedAt)
        if calendar.isDateInToday(call.startedAt) {
            return language == .zh ? "今天 \(time)" : "Today \(time)"
        }
        if calendar.isDateInYesterday(call.startedAt) {
            return language == .zh ? "昨天 \(time)" : "Yesterday \(time)"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .zh ? "zh_CN" : "en_US")
        formatter.dateFormat = language == .zh ? "M月d日 HH:mm" : "MMM d HH:mm"
        return formatter.string(from: call.startedAt)
    }
    
    var body: some View {
        // 不要套 NavigationStack：本视图是 ZStack overlay 层（不是 push 进来的）。
        // 嵌套 NavigationStack 的 .toolbar(.cancellationAction) 在刚 dismiss 完
        // fullScreenCover（如 LiveCallView）后会和上层 SwiftUI dismiss 链冲突，导致
        // 左上角返回按钮要点 3-4 次 action 才生效（按钮视觉按下动画正常）。改用自定义
        // header，避免触发 NavigationStack 的内部 dismiss 路径。
        GeometryReader { geo in
            VStack(spacing: 0) {
                header(topInset: geo.safeAreaInsets.top)
                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 18) {
                                analysisSection
                                transcriptSection
                                if selectedFeedbackType != nil {
                                    feedbackChatSection
                                        .id(feedbackChatAnchor)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, selectedFeedbackType != nil ? 130 : 140)
                        }
                        .onChange(of: selectedFeedbackType) { _, newValue in
                            guard newValue != nil, shouldAutoScrollToFeedback else { return }
                            shouldAutoScrollToFeedback = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                withAnimation(.easeInOut(duration: 0.45)) {
                                    proxy.scrollTo(feedbackChatAnchor, anchor: .bottom)
                                }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                                voiceHintActive = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                                voiceHintActive = false
                            }
                        }
                        .onChange(of: feedbackMessageCount) { _, _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo(feedbackChatBottomAnchor, anchor: .center)
                                }
                            }
                        }
                    }

                    if selectedFeedbackType == nil {
                        ratingGlassCard
                    } else {
                        combinedBottomCard(screenFrameInGlobal: screenFrameInGlobal)
                            .opacity(feedbackVoiceControl.isRecording ? 0 : 1)
                    }

                    if feedbackVoiceControl.isRecording {
                        VoiceRecordingOverlay(language: language, isCancelling: isVoiceCancelling)
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ScreenFramePreferenceKey.self, value: g.frame(in: .global))
                })
            }
            .ignoresSafeArea(edges: .top)
        }
        .onPreferenceChange(ScreenFramePreferenceKey.self) { screenFrameInGlobal = $0 }
        .background {
            detailBackground.ignoresSafeArea()
        }
        .onAppear {
            if let name = call.recordingFileName {
                if let url = try? CallAudioStore.url(forFileName: name) {
                    recordingPlayer.load(url: url)
                    sliderTime = 0
                    currentTime = 0
                    hasStartedPlayback = false
                }
            }
            if selectedFeedbackType == nil, let saved = call.feedback.last?.ratingRaw {
                shouldAutoScrollToFeedback = false
                selectedFeedbackType = saved
            }
            print("[StrangerTag][Detail] phone=\(call.phone) label=\(call.label) repeatCallCount=\(repeatCallCount) tag=\(strangerRepeatTagText ?? "nil")")
        }
        .onDisappear {
            recordingPlayer.stop()
        }
    }
    
    private func header(topInset: CGFloat) -> some View {
        HStack {
            Button { onBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(hex: "007AFF"))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            VStack(spacing: 2) {
                Text(detailNavigationTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                if !isTest {
                    headerMetaRow
                }
            }
            
            Spacer()
            
            if hasDialablePhone {
                Button {
                    openDialerWithNumber(call.phone)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(hex: "34C759").opacity(0.10))
                            .frame(width: 36, height: 36)
                        Image(systemName: "phone")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color(hex: "34C759"))
                    }
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, max(topInset, 20) + 6)
        .padding(.bottom, 10)
    }
    
    /// 打开系统拨号界面并填入号码，方便用户回拨
    private func openDialerWithNumber(_ phone: String) {
        let allowed = CharacterSet(charactersIn: "0123456789+*#")
        let trimmed = String(phone.unicodeScalars.filter { allowed.contains($0) })
        guard !trimmed.isEmpty, let url = URL(string: "tel:\(trimmed)") else { return }
        UIApplication.shared.open(url)
    }
    
    private var callInfoCard: some View {
        VStack(spacing: AppSpacing.md) {
            // Avatar and basic info
            VStack(spacing: AppSpacing.sm) {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 72, height: 72)
                    .overlay(
                        Image(systemName: statusIcon)
                            .font(DS.Typography.title.weight(.semibold))
                            .foregroundColor(statusColor)
                    )
                
                Text(detailDisplayName)
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)
                
                HStack(spacing: AppSpacing.xs) {
                    Text(call.phone)
                        .font(AppTypography.subheadline)
                        .foregroundColor(AppColors.textSecondary)
                    if let tag = strangerRepeatTagText {
                        Text(tag)
                            .font(AppTypography.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(repeatTagColor)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, AppSpacing.xs)
                            .padding(.vertical, 2)
                            .background(repeatTagColor.opacity(0.12))
                            .cornerRadius(AppRadius.sm)
                    }
                }
            }
            .padding(.top, AppSpacing.sm)
            
            Divider()
                .padding(.vertical, AppSpacing.xs)
            
            // Stats
            HStack(spacing: AppSpacing.xl) {
                StatItem(
                    icon: "clock",
                    value: formatDuration(call.durationSeconds),
                    label: t("时长", "Duration"),
                    language: language
                )
                
                Divider()
                    .frame(height: 32)
                
                StatItem(
                    icon: "calendar",
                    value: formatDate(call.startedAt),
                    label: t("日期", "Date"),
                    language: language
                )
            }
            .padding(.bottom, AppSpacing.sm)
        }
        .padding(AppSpacing.lg)
        .background(AppColors.surface)
        .cornerRadius(AppRadius.xl)
        .appShadow(AppShadow.md)
    }
    
    private var statusColor: Color {
        if isPlaceholderLabel && !call.isOutboundCall {
            return AppColors.error
        } else if trimmedLabel.contains("快递") || trimmedLabel.contains("外卖") || trimmedLabel.contains("Delivery") {
            return AppColors.warning
        } else {
            return AppColors.success
        }
    }
    
    private var statusIcon: String {
        if isPlaceholderLabel && !call.isOutboundCall {
            return "questionmark"
        } else if trimmedLabel.contains("快递") || trimmedLabel.contains("外卖") || trimmedLabel.contains("Delivery") {
            return "shippingbox.fill"
        } else {
            return "checkmark"
        }
    }
    
    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            VStack(spacing: AppSpacing.md) {
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(AppColors.backgroundSecondary)
                            .frame(height: 4)
                            .cornerRadius(AppSpacing.xxs)
                        
                        Rectangle()
                            .fill(AppColors.primary)
                            .frame(width: geometry.size.width * (sliderTime / Double(max(1, totalDuration))), height: 4)
                            .cornerRadius(AppSpacing.xxs)
                    }
                }
                .frame(height: 4)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            let percent = value.location.x / UIScreen.main.bounds.width
                            sliderTime = max(0, min(Double(totalDuration), percent * Double(totalDuration)))
                        }
                        .onEnded { _ in
                            recordingPlayer.seek(to: sliderTime)
                            isScrubbing = false
                        }
                )
                
                HStack {
                    Text(formatTime(hasStartedPlayback ? currentTime : 0))
                        .font(AppTypography.caption1)
                        .foregroundColor(AppColors.textSecondary)
                        .monospacedDigit()
                    
                    Spacer()
                    
                    Button {
                        if !recordingPlayer.isPlaying {
                            hasStartedPlayback = true
                        }
                        recordingPlayer.togglePlayPause()
                    } label: {
                        Image(systemName: recordingPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(DS.Typography.body.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(recordingPlayer.isReady ? AppColors.primary : AppColors.textSecondary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!recordingPlayer.isReady)
                    
                    Spacer()
                    
                    Text(formatTime(totalDuration))
                        .font(AppTypography.caption1)
                        .foregroundColor(AppColors.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(AppSpacing.md)
            .background(AppColors.surface)
            .cornerRadius(AppRadius.lg)
            .appShadow(AppShadow.sm)
        }
        .onReceive(recordingPlayer.$currentTime) { value in
            currentTime = Int(value)
            if !isScrubbing {
                sliderTime = value
            }
        }
    }
    
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !transcriptLines.isEmpty {
                VStack(spacing: 12) {
                    ForEach(transcriptLines) { line in
                        TranscriptBubble(
                            line: line,
                            currentTime: currentTime,
                            language: language
                        )
                    }
                }
            } else {
                Text(t("暂无转写记录", "No transcript available"))
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "8E8E93"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
            }
        }
    }
    
    private var analysisSection: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(red: 230/255, green: 240/255, blue: 1.0).opacity(0.75), location: 0),
                                .init(color: Color.white.opacity(0.60), location: 0.40),
                                .init(color: Color.white.opacity(0.50), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                    )
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color(hex: "007AFF"))
                            Text(t("AI 分析", "AI Analysis"))
                                .font(.system(size: 20, weight: .bold))
                                .tracking(-0.4)
                                .foregroundStyle(Color(hex: "1D1D1F"))
                        }
                        Spacer()
                        Text(analysisTimestampText)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: "8E8E93"))
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color(hex: "007AFF"))
                                Text(t("通话摘要", "Summary"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color(hex: "007AFF"))
                            }
                            Text(call.displaySummary ?? t("（无摘要）", "(No summary)"))
                                .font(.system(size: 16))
                                .foregroundStyle(Color(hex: "1D1D1F"))
                                .lineSpacing(4)
                                .tracking(-0.2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 12)
                        }

                        Rectangle()
                            .fill(Color.black.opacity(0.12))
                            .frame(height: 0.5)
                            .padding(.bottom, 12)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color(hex: "007AFF"))
                                Text(t("AI 应对", "AI Reply"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color(hex: "007AFF"))
                            }
                            Text(call.displayFullSummary ?? t("（无应对结果）", "(No suggestion)"))
                                .font(.system(size: 16))
                                .foregroundStyle(Color(hex: "1D1D1F"))
                                .lineSpacing(4)
                                .tracking(-0.2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(red: 235/255, green: 244/255, blue: 1.0).opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if recordingPlayer.isReady {
                        VStack(spacing: 10) {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color(hex: "007AFF").opacity(0.12))
                                        .frame(height: 2)
                                    Capsule()
                                        .fill(Color(hex: "007AFF"))
                                        .frame(width: geometry.size.width * (sliderTime / Double(max(1, totalDuration))), height: 2)
                                    Circle()
                                        .fill(Color(hex: "007AFF"))
                                        .frame(width: 14, height: 14)
                                        .offset(x: max(0, min(geometry.size.width - 14, geometry.size.width * (sliderTime / Double(max(1, totalDuration))) - 7)))
                                }
                            }
                            .frame(height: 18)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        isScrubbing = true
                                        let progress = min(max(0, value.location.x / max(1, UIScreen.main.bounds.width - 72)), 1)
                                        sliderTime = progress * Double(totalDuration)
                                    }
                                    .onEnded { value in
                                        let progress = min(max(0, value.location.x / max(1, UIScreen.main.bounds.width - 72)), 1)
                                        sliderTime = progress * Double(totalDuration)
                                        recordingPlayer.seek(to: sliderTime)
                                        isScrubbing = false
                                    }
                            )

                            HStack(alignment: .center) {
                                Text(formatTime(hasStartedPlayback ? currentTime : 0))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: "8E8E93"))
                                    .monospacedDigit()
                                    .frame(width: 36, alignment: .leading)
                                Spacer()
                                Button {
                                    if !recordingPlayer.isPlaying {
                                        hasStartedPlayback = true
                                    }
                                    recordingPlayer.togglePlayPause()
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: "007AFF"))
                                            .frame(width: 32, height: 32)
                                        Image(systemName: recordingPlayer.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                            .offset(x: recordingPlayer.isPlaying ? 0 : 1)
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Text(formatTime(totalDuration))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: "8E8E93"))
                                    .monospacedDigit()
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
        }
        .onReceive(recordingPlayer.$currentTime) { value in
            currentTime = Int(value)
            if !isScrubbing {
                sliderTime = value
            }
        }
    }
    
    private func combinedBottomCard(screenFrameInGlobal: CGRect) -> some View {
        ChatComposerBar(
            language: language,
            isRecording: $feedbackVoiceControl.isRecording,
            onVoiceStart: { feedbackVoiceControl.beginCount += 1 },
            onVoiceSend: { feedbackVoiceControl.endCount += 1 },
            onVoiceCancel: { feedbackVoiceControl.cancelCount += 1 },
            onSendText: { text in
                feedbackVoiceControl.pendingText = text
                feedbackVoiceControl.sendTextCount += 1
            },
            onVoiceCancelStateChanged: { next in isVoiceCancelling = next },
            hintActive: voiceHintActive,
            screenFrameForSemicircleCancel: screenFrameInGlobal.width > 0 && screenFrameInGlobal.height > 0 ? screenFrameInGlobal : nil,
            useGlassContainer: true
        )
    }

    private var ratingGlassCard: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 20
        )

        return VStack(spacing: 10) {
            Text(isTest ? t("测试结果符合预期吗？", "Does this match expectations?") : t("点评AI分身的表现，让它下次做得更好", "Rate your AI avatar's performance so it can improve next time"))
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "8E8E93"))
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 24) {
                FeedbackButton(
                    icon: "hand.thumbsdown.fill",
                    label: t("不好", "Bad"),
                    color: AppColors.error
                ) { setFeedback("bad") }

                FeedbackButton(
                    icon: "minus.circle.fill",
                    label: t("一般", "Fair"),
                    color: AppColors.warning
                ) { setFeedback("average") }

                FeedbackButton(
                    icon: "hand.thumbsup.fill",
                    label: t("很好", "Good"),
                    color: AppColors.success
                ) { setFeedback("good") }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.34), Color(hex: "EDF3FF").opacity(0.22)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .frame(height: 300)
            .shadow(color: Color(hex: "64748B").opacity(0.055), radius: 14, y: -5)
            .shadow(color: Color(hex: "64748B").opacity(0.04), radius: 24, y: -16)
            .shadow(color: .white.opacity(0.26), radius: 8, y: -7)
        }
        .overlay(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color.white.opacity(0.9), location: 0.28),
                    .init(color: .white, location: 0.5),
                    .init(color: Color.white.opacity(0.9), location: 0.72),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.5)
            .padding(.horizontal, 28)
        }
        .overlay {
            shape.stroke(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.44), location: 0),
                        .init(color: Color.white.opacity(0.26), location: 0.5),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.5
            )
        }
        .padding(.horizontal, 16)
    }

    private var feedbackChatSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color(hex: "D1D1D6"))
                    .frame(height: 0.5)
                Text(t("结果点评", "Call Review"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: "8E8E93"))
                    .fixedSize()
                Rectangle()
                    .fill(Color(hex: "D1D1D6"))
                    .frame(height: 0.5)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)

            FeedbackChatModalView(
                language: language,
                feedbackType: selectedFeedbackType ?? "none",
                scene: .evaluation,
                onClose: { },
                isEmbedded: true,
                inlineMessagesMode: true,
                voiceControl: feedbackVoiceControl,
                showCloseButton: false,
                initialMessages: feedbackInitialMessages(for: selectedFeedbackType),
                showInitialMessage: false,
                initMessagesOverride: feedbackInitMessages(for: selectedFeedbackType),
                evaluationChatHistoryOverride: evaluationChatHistory,
                autoPlayIntro: shouldAutoPlayFeedbackIntro,
                messagesPersistenceKey: "callmate.call_detail.feedback.\(call.id.uuidString)",
                onMessagesChanged: { feedbackMessageCount += 1 }
            )
            .padding(.top, 4)
            .padding(.horizontal, 16)

            Color.clear.frame(height: 1).id(feedbackChatBottomAnchor)
        }
    }

    private func stickyVoiceBar(screenFrameInGlobal: CGRect) -> some View {
        ChatComposerBar(
            language: language,
            isRecording: $feedbackVoiceControl.isRecording,
            onVoiceStart: {
                feedbackVoiceControl.beginCount += 1
            },
            onVoiceSend: {
                feedbackVoiceControl.endCount += 1
            },
            onVoiceCancel: {
                feedbackVoiceControl.cancelCount += 1
            },
            onSendText: { text in
                feedbackVoiceControl.pendingText = text
                feedbackVoiceControl.sendTextCount += 1
            },
            onVoiceCancelStateChanged: { next in
                isVoiceCancelling = next
            },
            hintActive: voiceHintActive,
            screenFrameForSemicircleCancel: screenFrameInGlobal.width > 0 && screenFrameInGlobal.height > 0 ? screenFrameInGlobal : nil
        )
    }

    private func feedbackIconName(for type: String?) -> String {
        switch type {
        case "good": return "hand.thumbsup.fill"
        case "bad": return "hand.thumbsdown.fill"
        default: return "minus.circle.fill"
        }
    }

    private func feedbackIconColor(for type: String?) -> Color {
        switch type {
        case "good": return AppColors.success
        case "bad": return AppColors.error
        default: return AppColors.warning
        }
    }

    private func userRatingText(for type: String?) -> String {
        switch type {
        case "good": return t("这次服务很好。", "The service was great this time.")
        case "bad": return t("这次服务不太好。", "The service was not good this time.")
        case "average": return t("这次服务一般。", "The service was average.")
        default: return t("我想补充一下这通电话的反馈。", "I want to add feedback for this call.")
        }
    }

    private func feedbackInitialMessages(for type: String?) -> [ExtendedMessage] {
        [
            ExtendedMessage(
                id: Int.random(in: 10000...99999),
                sender: .user,
                text: userRatingText(for: type),
                msgType: .text
            )
        ]
    }
    
    private func setFeedback(_ type: String) {
        let isFirstFeedback = call.feedback.isEmpty
        shouldAutoScrollToFeedback = true
        shouldAutoPlayFeedbackIntro = isFirstFeedback
        selectedFeedbackType = type

        let record = CallFeedback(ratingRaw: type, note: nil, call: call)
        call.feedback.append(record)
        modelContext.insert(record)
        try? modelContext.save()
    }

    private func feedbackOpeningText(for type: String?) -> String {
        switch type {
        case "good":
            return t("谢谢鼓励！你可以按住说话告诉我做得好的地方。", "Thanks! Hold to talk and tell me what worked well.")
        case "bad":
            return t("抱歉这次体验不好。你可以按住说话告诉我哪里需要改进。", "Sorry this wasn't great. Hold to talk and tell me what to improve.")
        case "average":
            return t("收到你的评价。你可以按住说话补充更多细节。", "Got it. Hold to talk and share more details.")
        default:
            return t("你可以按住说话，继续补充本次通话反馈。", "Hold to talk and share more feedback for this call.")
        }
    }

    private func feedbackInitMessages(for type: String?) -> [[String: String]] {
        let userSeed: String
        switch type {
        case "good":
            userSeed = t("这次服务很好。", "The service was great this time.")
        case "bad":
            userSeed = t("这次服务不太好。", "The service was not good this time.")
        case "average":
            userSeed = t("这次服务一般。", "The service was average.")
        default:
            userSeed = t("我想补充一下这通电话的反馈。", "I want to add feedback for this call.")
        }
        return [
            ["role": "user", "content": userSeed],
            ["role": "assistant", "content": feedbackOpeningText(for: type)]
        ]
    }

    private var evaluationChatHistory: [[String: String]] {
        transcriptLines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let role = (line.senderRaw == ChatSender.ai.rawValue) ? "assistant" : "other"
            return ["role": role, "content": text]
        }
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            let m = seconds / 60
            let s = seconds % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .zh ? "zh_CN" : "en_US")
        formatter.dateFormat = language == .zh ? "M月d日" : "MMM d"
        return formatter.string(from: date)
    }
}

// MARK: - Helper Components
private struct StatItem: View {
    let icon: String
    let value: String
    let label: String
    let language: Language
    
    var body: some View {
        VStack(spacing: AppSpacing.xs) {
            Image(systemName: icon)
                .font(DS.Typography.body)
                .foregroundColor(AppColors.textSecondary)
            
            Text(value)
                .font(AppTypography.bodyEmphasized)
                .foregroundColor(AppColors.textPrimary)
            
            Text(label)
                .font(AppTypography.caption2)
                .foregroundColor(AppColors.textSecondary)
        }
    }
}

private struct TranscriptBubble: View {
    let line: TranscriptLine
    let currentTime: Int
    let language: Language
    
    var body: some View {
        let isAI = line.senderRaw == ChatSender.ai.rawValue
        let startSec = (line.startOffsetMs ?? -1) / 1000
        let endSec = (line.endOffsetMs ?? -1) / 1000
        let isActive = (line.startOffsetMs != nil && line.endOffsetMs != nil)
            ? (currentTime >= startSec && currentTime <= endSec)
            : false

        let bubbleShape = UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: isAI ? 18 : 4,
            bottomTrailingRadius: isAI ? 4 : 18,
            topTrailingRadius: 18
        )

        HStack {
            if isAI { Spacer(minLength: UIScreen.main.bounds.width * 0.25) }
            Text(line.text)
                .font(.system(size: 17))
                .foregroundStyle(isAI ? .white : AppColors.textPrimary)
                .lineSpacing(6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    if isAI {
                        bubbleShape.fill(Color(hex: "007AFF"))
                    } else {
                        bubbleShape
                            .fill(.ultraThinMaterial)
                            .overlay {
                                bubbleShape.fill(Color.white.opacity(0.82))
                            }
                            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
                            .overlay {
                                bubbleShape.stroke(
                                    isActive ? Color(hex: "007AFF").opacity(0.35) : Color.white.opacity(0.7),
                                    lineWidth: 0.5
                                )
                            }
                    }
                }
                .clipShape(bubbleShape)
            if !isAI { Spacer(minLength: UIScreen.main.bounds.width * 0.2) }
        }
    }
}

private struct AnalysisRow: View {
    let label: String
    let value: String
    let language: Language
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(label)
                .font(AppTypography.caption1)
                .fontWeight(.semibold)
                .foregroundColor(AppColors.accent)
            
            Text(value)
                .font(AppTypography.body)
                .foregroundColor(AppColors.textPrimary)
        }
    }
}

private struct FeedbackButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 48, height: 48)
                    .background(color.opacity(0.07))
                    .clipShape(Circle())
                
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 110/255, green: 110/255, blue: 115/255))
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    CallDetailView(
        call: CallLog(
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 65,
            statusRaw: CallStatus.handled.rawValue,
            phone: "138****2072",
            label: "未知来电",
            summary: "快递员询问收货地址",
            fullSummary: "快递员表示有您的包裹，询问具体收货地址。AI 助手已告知放在门口即可。",
            isSimulation: false,
            languageRaw: Language.zh.rawValue
        ),
        language: .zh,
        isTest: false,
        onBack: {}
    )
}

private struct ScreenFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
