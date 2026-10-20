import Foundation
import Network
import Combine

@MainActor
final class DeviceConditions: ObservableObject {
    static let shared = DeviceConditions()

    @Published private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var isLowDataMode = false

    private let monitor = NWPathMonitor()
    private var observer: NSObjectProtocol?

    var limitsAnimation: Bool { isLowPowerMode || isLowDataMode }

    var reason: String? {
        switch (isLowPowerMode, isLowDataMode) {
        case (true, true): "Unavailable in Low Power Mode and Low Data Mode."
        case (true, false): "Unavailable in Low Power Mode."
        case (false, true): "Unavailable in Low Data Mode."
        case (false, false): nil
        }
    }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
        monitor.pathUpdateHandler = { path in
            let constrained = path.isConstrained
            Task { @MainActor in DeviceConditions.shared.isLowDataMode = constrained }
        }
        monitor.start(queue: DispatchQueue(label: "com.swagrelated.scrap.network"))
    }
}
