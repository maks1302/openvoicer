import AVFoundation
import Observation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isConnected: Bool
}

@MainActor
@Observable
final class AudioDeviceManager {
    private(set) var devices: [AudioInputDevice] = []

    init() {
        refresh()
    }

    func refresh() {
        devices = Self.captureDevices().map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName, isConnected: $0.isConnected)
        }
    }

    nonisolated static func captureDevice(withID id: String?) -> AVCaptureDevice? {
        let available = captureDevices()
        guard let id else { return AVCaptureDevice.default(for: .audio) ?? available.first }
        return available.first { $0.uniqueID == id }
    }

    nonisolated private static func captureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        .devices
        .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }
}
