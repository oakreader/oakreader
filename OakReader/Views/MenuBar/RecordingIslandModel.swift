import SwiftUI

@Observable
final class RecordingIslandModel {
    enum IslandState {
        case hidden
        case collapsed
        case expanded
    }

    var state: IslandState = .hidden
    var isNotchedDisplay: Bool = false
    var notchWidth: CGFloat = 180
    var notchHeight: CGFloat = 38
    var elapsedTime: String = "00:00"

    // Recording info
    var recordingMode: String = "micOnly"
    var inputDeviceName: String = "System Default"

    var isExpanded: Bool {
        state == .expanded
    }

    /// The pill width when collapsed.
    var collapsedWidth: CGFloat {
        if isNotchedDisplay {
            return notchWidth + 88 // 44pt padding each side
        }
        return 200
    }

    /// The pill height when collapsed.
    var collapsedHeight: CGFloat {
        if isNotchedDisplay {
            return notchHeight
        }
        return 32
    }

    func toggle() {
        switch state {
        case .hidden:
            break
        case .collapsed:
            state = .expanded
        case .expanded:
            state = .collapsed
        }
    }

    func collapse() {
        if state == .expanded {
            state = .collapsed
        }
    }
}
