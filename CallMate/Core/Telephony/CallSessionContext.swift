import Foundation

struct CallSessionContext {
    let ws: WebSocketService
    let audio: AudioService
    let ble: any CallMateBLELibraryClient
}

struct CallSessionState {
    var status: CallSessionController.Status
    var duration: Int
    var wsSessionId: String?
}
