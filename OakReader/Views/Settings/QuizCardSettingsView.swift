import SwiftUI

struct QuizCardSettingsView: View {
    @AppStorage("quizCard_targetRetention") private var targetRetention: Double = 0.9
    @AppStorage("quizCard_maxInterval") private var maxInterval: Int = 36500
    @AppStorage("quizCard_dailyNewLimit") private var dailyNewLimit: Int = 20
    @AppStorage("quizCard_ratingButtonCount") private var ratingButtonCount: Int = 2
    @AppStorage("quizCard_leechThreshold") private var leechThreshold: Int = 6
    @AppStorage("quizCard_autoSuspendLeech") private var autoSuspendLeech: Bool = true

    var body: some View {
        Form {
            Section("Scheduling (FSRS)") {
                LabeledContent("Target Retention") {
                    HStack {
                        Slider(value: $targetRetention, in: 0.7...0.99, step: 0.01)
                        Text("\(Int(targetRetention * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                LabeledContent("Maximum Interval") {
                    HStack {
                        TextField("Days", value: $maxInterval, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("days")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Daily New Cards") {
                    HStack {
                        Stepper(value: $dailyNewLimit, in: 1...200) {
                            Text("\(dailyNewLimit)")
                                .monospacedDigit()
                        }
                    }
                }
            }

            Section("Review") {
                Picker("Rating Buttons", selection: $ratingButtonCount) {
                    Text("2 (Forget / Remember)").tag(2)
                    Text("4 (Again / Hard / Good / Easy)").tag(4)
                }
            }

            Section("Leech Detection") {
                LabeledContent("Leech Threshold") {
                    Stepper(value: $leechThreshold, in: 3...20) {
                        Text("\(leechThreshold) lapses")
                            .monospacedDigit()
                    }
                }

                Toggle("Auto-Suspend Leeches", isOn: $autoSuspendLeech)
            }

            Section {
                Text("FSRS (Free Spaced Repetition Scheduler) optimizes review intervals based on your performance. Higher retention means more frequent reviews.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}
