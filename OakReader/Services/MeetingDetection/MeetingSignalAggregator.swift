import Foundation

/// Fuses signals from multiple `MeetingDetector` conformers using noisy-OR probability combination.
/// Maintains confirmation counters to prevent transient false positives/negatives.
final class MeetingSignalAggregator: Sendable {

    let detectors: [any MeetingDetector]

    /// Number of consecutive positive polls required before declaring a meeting.
    let confirmationCount: Int

    /// Number of consecutive negative polls required before ending a meeting.
    let endGraceCount: Int

    init(
        detectors: [any MeetingDetector],
        confirmationCount: Int = 2,
        endGraceCount: Int = 3
    ) {
        self.detectors = detectors
        self.confirmationCount = confirmationCount
        self.endGraceCount = endGraceCount
    }

    /// Run all detectors concurrently and fuse their signals into per-app assessments.
    func assess() async -> [MeetingAssessment] {
        let allSignals = await withTaskGroup(of: [MeetingSignal].self) { group in
            for detector in detectors {
                group.addTask {
                    await detector.detect()
                }
            }

            var collected: [MeetingSignal] = []
            for await signals in group {
                collected.append(contentsOf: signals)
            }
            return collected
        }

        // Group signals by app (bundleID)
        var grouped: [String: (app: MeetingAppIdentifier, signals: [MeetingSignal])] = [:]
        for signal in allSignals {
            let key = signal.appIdentifier.bundleID
            if var existing = grouped[key] {
                existing.signals.append(signal)
                grouped[key] = existing
            } else {
                grouped[key] = (app: signal.appIdentifier, signals: [signal])
            }
        }

        // Compute fused confidence per app using noisy-OR: 1 - Π(1 - pᵢ)
        var assessments: [MeetingAssessment] = []
        for (_, entry) in grouped {
            let fusedConfidence = noisyOR(entry.signals.map(\.confidence))
            assessments.append(MeetingAssessment(
                candidate: entry.app,
                confidence: fusedConfidence,
                signals: entry.signals
            ))
        }

        // Sort by confidence descending
        assessments.sort { $0.confidence > $1.confidence }
        return assessments
    }

    /// Pick the best assessment that passes the meeting threshold.
    func bestAssessment() async -> MeetingAssessment? {
        let assessments = await assess()
        return assessments.first { $0.isMeeting }
    }

    // MARK: - Noisy-OR

    private func noisyOR(_ probabilities: [Double]) -> Double {
        guard !probabilities.isEmpty else { return 0.0 }
        let productOfComplements = probabilities.reduce(1.0) { $0 * (1.0 - $1) }
        return 1.0 - productOfComplements
    }
}
