import Foundation
import ActivityKit

struct CallMateLiveActivityAttributes: ActivityAttributes {

    enum Phase: String, Codable, Hashable {
        case calling
        case ended
        case summary
    }

    public struct ContentState: Codable, Hashable {
        var statusText: String
        var durationSeconds: Int
        var ttsText: String
        var sttText: String
        var callerName: String
        var callerNumber: String
        var canHandoff: Bool
        var canHangup: Bool
        var phase: Phase
        var summaryTitle: String
        var summaryDetail: String

        init(
            statusText: String,
            durationSeconds: Int,
            ttsText: String,
            sttText: String = "",
            callerName: String,
            callerNumber: String,
            canHandoff: Bool,
            canHangup: Bool,
            phase: Phase = .calling,
            summaryTitle: String = "",
            summaryDetail: String = ""
        ) {
            self.statusText = statusText
            self.durationSeconds = durationSeconds
            self.ttsText = ttsText
            self.sttText = sttText
            self.callerName = callerName
            self.callerNumber = callerNumber
            self.canHandoff = canHandoff
            self.canHangup = canHangup
            self.phase = phase
            self.summaryTitle = summaryTitle
            self.summaryDetail = summaryDetail
        }
    }

    var callId: String
}
