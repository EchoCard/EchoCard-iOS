import Foundation

struct VoiceCloneTrainResponse: Decodable {
    struct DataObj: Decodable {
        let speaker_id: String
        let state: String
    }
    let data: DataObj
}

struct VoiceCloneStatusResponse: Decodable {
    struct DataObj: Decodable {
        let speaker_id: String
        let state: String?
        let train_failed_reason: String?
        let demo_audio: String?
        let expire_time: String?
        let can_train: Bool?
    }
    let data: DataObj
}

struct DeviceVoiceCloneResponse: Decodable {
    struct DataObj: Decodable {
        struct VoiceCloneInfo: Decodable {
            let speaker_id: String
            let state: String?
            let train_failed_reason: String?
            let demo_audio: String?
        }
        let device_id: String
        let voice_clone: VoiceCloneInfo?
    }
    let data: DataObj
}

struct TTSVoice: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    let demoURL: String?

    enum CodingKeys: String, CodingKey {
        case id = "voice_id"
        case name = "voice_name"
        case demoURL = "voice_demo_url"
    }
}

enum VoiceTone: String, CaseIterable, Identifiable {
    case taiwan
    case girl
    case ceo
    case kid

    var id: String { rawValue }

    func displayName(language: Language) -> String {
        switch (self, language) {
        case (.taiwan, .zh): return "湾湾小何"
        case (.taiwan, .en): return "Taiwanese"
        case (.girl, .zh): return "邻家女孩"
        case (.girl, .en): return "Girl"
        case (.ceo, .zh): return "霸道总裁"
        case (.ceo, .en): return "CEO"
        case (.kid, .zh): return "聪明小孩"
        case (.kid, .en): return "Kid"
        }
    }
}
