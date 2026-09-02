import Foundation
import UIKit

@MainActor
final class ThermalMonitor: ObservableObject {
    @Published private(set) var state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateDidChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var shouldReduceLoad: Bool {
        state == .serious || state == .critical
    }

    @objc private func thermalStateDidChange() {
        state = ProcessInfo.processInfo.thermalState
    }
}
