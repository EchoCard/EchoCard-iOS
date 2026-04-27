import ActivityKit
import AppIntents
import WidgetKit
import SwiftUI

private func formatDuration(_ seconds: Int) -> String {
    let m = max(0, seconds) / 60
    let s = max(0, seconds) % 60
    return String(format: "%02d:%02d", m, s)
}

private func shouldShowDuration(_ state: CallMateLiveActivityAttributes.ContentState) -> Bool {
    return state.canHandoff || state.canHangup || state.durationSeconds > 0
}

private struct AppMarkView: View {
    var compact: Bool = false

    var body: some View {
        Image("LiveAppIcon")
            .resizable()
            .scaledToFit()
            .frame(width: compact ? 16 : 18, height: compact ? 16 : 18)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Transcript bubble for Lock Screen

private struct TranscriptRow: View {
    let label: String
    let text: String
    let isAI: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isAI ? "brain.head.profile" : "person.wave.2")
                .font(.caption2)
                .foregroundStyle(isAI ? .blue : .green)
                .frame(width: 14)
            Text(text)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Lock Screen: Calling phase

private struct LockScreenCallingView: View {
    let state: CallMateLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.callerName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if shouldShowDuration(state) {
                    Text(formatDuration(state.durationSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("EchoCard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(state.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !state.sttText.isEmpty || !state.ttsText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !state.sttText.isEmpty {
                        TranscriptRow(label: "来电", text: state.sttText, isAI: false)
                    }
                    if !state.ttsText.isEmpty {
                        TranscriptRow(label: "AI", text: state.ttsText, isAI: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 10) {
                if state.canHandoff {
                    Button(intent: LiveCallHandoffIntent()) {
                        Label("真人接听", systemImage: "person.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.blue.opacity(0.2), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if state.canHangup {
                    Button(intent: LiveCallHangupIntent()) {
                        Label("挂断", systemImage: "phone.down.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.red.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Lock Screen: Ended / Summary phase

private struct LockScreenSummaryView: View {
    let state: CallMateLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.callerName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(formatDuration(state.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if state.phase == .summary && !state.summaryTitle.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.summaryTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        if !state.summaryDetail.isEmpty {
                            Text(state.summaryDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在生成通话摘要…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Dynamic Island: Calling bottom

private struct DynamicIslandCallingBottom: View {
    let state: CallMateLiveActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 6) {
            if !state.sttText.isEmpty || !state.ttsText.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if !state.sttText.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "person.wave.2")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                            Text(state.sttText)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    if !state.ttsText.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 8))
                                .foregroundStyle(.blue)
                            Text(state.ttsText)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if state.canHandoff {
                    Button(intent: LiveCallHandoffIntent()) {
                        Label("真人接听", systemImage: "person.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.blue.opacity(0.2), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if state.canHangup {
                    Button(intent: LiveCallHangupIntent()) {
                        Label("挂断", systemImage: "phone.down.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.red.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Dynamic Island: Summary bottom

private struct DynamicIslandSummaryBottom: View {
    let state: CallMateLiveActivityAttributes.ContentState

    var body: some View {
        if state.phase == .summary && !state.summaryTitle.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(state.summaryTitle)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                }
                if !state.summaryDetail.isEmpty {
                    Text(state.summaryDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } else {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("生成摘要中…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Widget

struct CallMateLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallMateLiveActivityAttributes.self) { context in
            Group {
                switch context.state.phase {
                case .calling:
                    LockScreenCallingView(state: context.state)
                case .ended, .summary:
                    LockScreenSummaryView(state: context.state)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.15))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let isCalling = context.state.phase == .calling
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AppMarkView()
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if isCalling && shouldShowDuration(context.state) {
                        Text(formatDuration(context.state.durationSeconds))
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.trailing, 6)
                    } else if !isCalling {
                        Text(formatDuration(context.state.durationSeconds))
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.trailing, 6)
                    } else {
                        Text("EchoCard")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.trailing, 6)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.statusText)
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if isCalling {
                        DynamicIslandCallingBottom(state: context.state)
                    } else {
                        DynamicIslandSummaryBottom(state: context.state)
                    }
                }
            } compactLeading: {
                AppMarkView(compact: true)
            } compactTrailing: {
                if isCalling {
                    if shouldShowDuration(context.state) {
                        Text(formatDuration(context.state.durationSeconds))
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Text("EC")
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                } else {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } minimal: {
                AppMarkView(compact: true)
            }
            .widgetURL(URL(string: "callmate://livecall/open"))
            .keylineTint(isCalling ? .green : .orange)
        }
    }
}
