import SwiftUI

struct QuizCardSettingsView: View {
    @AppStorage("quizCard_targetRetention") private var targetRetention: Double = 0.9
    @AppStorage("quizCard_maxInterval") private var maxInterval: Int = 36500
    @AppStorage("quizCard_dailyNewLimit") private var dailyNewLimit: Int = 20
    @AppStorage("quizCard_reviewMode") private var reviewMode: String = "production"
    @AppStorage("quizCard_feedbackMode") private var feedbackMode: String = "simple"

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
                Picker("Default Mode", selection: $reviewMode) {
                    ForEach(ReviewMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }

                Picker("Feedback Detail", selection: $feedbackMode) {
                    ForEach(EvaluationFeedbackMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
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
