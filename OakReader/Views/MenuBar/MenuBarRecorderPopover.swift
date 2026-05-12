import SwiftUI
import OakVoiceAI

struct MenuBarRecorderPopover: View {
    let recorder: MenuBarRecorder

    @State private var selectedDeviceUID: String?

    private var devices: [AudioDevice] {
        AudioDeviceManager.shared.inputDevices
    }

    private var isRecording: Bool {
        recorder.recordingService.state == .recording
    }

    private var isStopping: Bool {
        recorder.recordingService.state == .stopping
    }

    var body: some View {
        VStack(spacing: 12) {
            // Meeting detection banner
            if let meeting = recorder.meetingDetection.detectedMeeting, !isRecording {
                HStack(spacing: 6) {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.orange)
                    Text("\(meeting.appName) detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            // Device picker
            Picker("Input Device", selection: $selectedDeviceUID) {
                Text("System Default")
                    .tag(nil as String?)
                ForEach(devices) { device in
                    Text(device.name)
                        .tag(device.uniqueID as String?)
                }
            }
            .labelsHidden()
            .disabled(isRecording || isStopping)

            // Elapsed time
            if isRecording {
                Text(recorder.recordingService.formattedElapsedTime)
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
            }

            // Record / Stop button
            Button {
                if isRecording {
                    recorder.stopRecording()
                } else {
                    recorder.startRecording(deviceUID: selectedDeviceUID)
                }
            } label: {
                HStack {
                    Image(systemName: isRecording ? "stop.fill" : "record.circle")
                    Text(isRecording ? "Stop" : "Record")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isRecording ? .red : .accentColor)
            .controlSize(.large)
            .disabled(isStopping)
        }
        .padding()
        .frame(width: 260)
    }
}
