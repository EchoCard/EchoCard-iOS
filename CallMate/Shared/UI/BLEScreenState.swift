import Foundation
import Combine
import CoreBluetooth

struct CallsBLEViewSnapshot: Equatable {
    let bluetoothState: CBManagerState
    let isReady: Bool
    let isCtrlReady: Bool
    let connectingPeripheralID: UUID?
    let connectedPeripheralID: UUID?
    let deviceFirmwareVersion: String?
    let deviceANCSEnabled: Bool?

    init(runtime: CallMateBLERuntimeSnapshot) {
        bluetoothState = runtime.bluetoothState
        isReady = runtime.isReady
        isCtrlReady = runtime.isCtrlReady
        connectingPeripheralID = runtime.connectingPeripheralID
        connectedPeripheralID = runtime.connectedPeripheralID
        deviceFirmwareVersion = runtime.deviceFirmwareVersion
        deviceANCSEnabled = runtime.deviceANCSEnabled
    }
}

@MainActor
final class CallsBLEViewState: ObservableObject {
    @Published private(set) var snapshot: CallsBLEViewSnapshot

    private let ble: any CallMateBLELibraryClient
    private var cancellables: Set<AnyCancellable> = []

    convenience init() {
        self.init(ble: CallMateBLEClient.shared)
    }

    init(ble: any CallMateBLELibraryClient) {
        self.ble = ble
        self.snapshot = CallsBLEViewSnapshot(runtime: ble.runtimeSnapshot)

        ble.runtimeSnapshotPublisher
            .sink { [weak self] runtime in
                self?.refresh(with: runtime)
            }
            .store(in: &cancellables)
    }

    private func refresh(with runtime: CallMateBLERuntimeSnapshot) {
        let next = CallsBLEViewSnapshot(runtime: runtime)
        guard next != snapshot else { return }
        snapshot = next
    }
}

struct OutboundBLEViewSnapshot: Equatable {
    let bluetoothState: CBManagerState
    let isReady: Bool
    let connectingPeripheralID: UUID?
    let connectedPeripheralID: UUID?

    init(runtime: CallMateBLERuntimeSnapshot) {
        bluetoothState = runtime.bluetoothState
        isReady = runtime.isReady
        connectingPeripheralID = runtime.connectingPeripheralID
        connectedPeripheralID = runtime.connectedPeripheralID
    }
}

@MainActor
final class OutboundBLEViewState: ObservableObject {
    @Published private(set) var snapshot: OutboundBLEViewSnapshot

    private let ble: any CallMateBLELibraryClient
    private var cancellables: Set<AnyCancellable> = []

    convenience init() {
        self.init(ble: CallMateBLEClient.shared)
    }

    init(ble: any CallMateBLELibraryClient) {
        self.ble = ble
        self.snapshot = OutboundBLEViewSnapshot(runtime: ble.runtimeSnapshot)

        ble.runtimeSnapshotPublisher
            .sink { [weak self] runtime in
                self?.refresh(with: runtime)
            }
            .store(in: &cancellables)
    }

    private func refresh(with runtime: CallMateBLERuntimeSnapshot) {
        let next = OutboundBLEViewSnapshot(runtime: runtime)
        guard next != snapshot else { return }
        snapshot = next
    }
}

struct ContentViewBLEViewSnapshot: Equatable {
    let lastIncomingCall: CallMateIncomingCall?
    let runtimeMCUDeviceID: String?
    let deviceANCSEnabled: Bool?
    let pendingDeviceStrategy: String?

    init(runtime: CallMateBLERuntimeSnapshot) {
        lastIncomingCall = runtime.lastIncomingCall
        runtimeMCUDeviceID = runtime.runtimeMCUDeviceID
        deviceANCSEnabled = runtime.deviceANCSEnabled
        pendingDeviceStrategy = runtime.pendingDeviceStrategy
    }
}

/// Narrow projection of the BLE runtime used by `ContentView`.
///
/// The concrete BLE client exposes a wide surface area, so this snapshot only
/// forwards the handful of fields ContentView actually consumes via `.onChange`.
@MainActor
final class ContentViewBLEViewState: ObservableObject {
    @Published private(set) var snapshot: ContentViewBLEViewSnapshot

    private let ble: any CallMateBLELibraryClient
    private var cancellables: Set<AnyCancellable> = []

    convenience init() {
        self.init(ble: CallMateBLEClient.shared)
    }

    init(ble: any CallMateBLELibraryClient) {
        self.ble = ble
        self.snapshot = ContentViewBLEViewSnapshot(runtime: ble.runtimeSnapshot)

        ble.runtimeSnapshotPublisher
            .sink { [weak self] runtime in
                self?.refresh(with: runtime)
            }
            .store(in: &cancellables)
    }

    private func refresh(with runtime: CallMateBLERuntimeSnapshot) {
        let next = ContentViewBLEViewSnapshot(runtime: runtime)
        guard next != snapshot else { return }
        snapshot = next
    }
}

struct DeviceModalBLEViewSnapshot: Equatable {
    let bluetoothState: CBManagerState
    let isCtrlReady: Bool
    let isReady: Bool
    let isKVReady: Bool
    let connectingPeripheralID: UUID?
    let connectedPeripheralID: UUID?
    let connectedDeviceName: String?
    let deviceBLEBondState: String?
    let deviceHFPState: String?
    let deviceFirmwareVersion: String?
    let deviceBattery: Int?
    let deviceCharging: Bool?

    init(runtime: CallMateBLERuntimeSnapshot) {
        bluetoothState = runtime.bluetoothState
        isCtrlReady = runtime.isCtrlReady
        isReady = runtime.isReady
        isKVReady = runtime.isKVReady
        connectingPeripheralID = runtime.connectingPeripheralID
        connectedPeripheralID = runtime.connectedPeripheralID
        connectedDeviceName = runtime.connectedDeviceName
        deviceBLEBondState = runtime.deviceBLEBondState
        deviceHFPState = runtime.deviceHFPState
        deviceFirmwareVersion = runtime.deviceFirmwareVersion
        deviceBattery = runtime.deviceBattery
        deviceCharging = runtime.deviceCharging
    }
}

@MainActor
final class DeviceModalBLEViewState: ObservableObject {
    @Published private(set) var snapshot: DeviceModalBLEViewSnapshot

    private let ble: any CallMateBLELibraryClient
    private var cancellables: Set<AnyCancellable> = []

    convenience init() {
        self.init(ble: CallMateBLEClient.shared)
    }

    init(ble: any CallMateBLELibraryClient) {
        self.ble = ble
        self.snapshot = DeviceModalBLEViewSnapshot(runtime: ble.runtimeSnapshot)

        ble.runtimeSnapshotPublisher
            .sink { [weak self] runtime in
                self?.refresh(with: runtime)
            }
            .store(in: &cancellables)
    }

    private func refresh(with runtime: CallMateBLERuntimeSnapshot) {
        let next = DeviceModalBLEViewSnapshot(runtime: runtime)
        guard next != snapshot else { return }
        snapshot = next
    }
}
