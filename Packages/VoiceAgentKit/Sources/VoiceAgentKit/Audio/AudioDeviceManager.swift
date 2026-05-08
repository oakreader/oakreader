import AVFoundation
import CoreAudio

// MARK: - AudioDevice

public struct AudioDevice: Identifiable, Hashable, Sendable {
    /// CoreAudio numeric ID (transient — changes across reboots / re-plug).
    public let id: AudioDeviceID
    /// Persistent unique identifier, stable across reboots.
    public let uniqueID: String
    /// Human-readable device name.
    public let name: String
    /// Whether the device has input (microphone) streams.
    public let hasInput: Bool
    /// Whether the device has output (speaker) streams.
    public let hasOutput: Bool
}

// MARK: - AudioDeviceManager

@Observable
public final class AudioDeviceManager: @unchecked Sendable {
    public static let shared = AudioDeviceManager()

    public private(set) var inputDevices: [AudioDevice] = []
    public private(set) var outputDevices: [AudioDevice] = []

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        refreshDevices()
        installHotPlugListener()
    }

    deinit {
        removeHotPlugListener()
    }

    // MARK: - Device Resolution

    /// Resolve a persistent UID string to a transient `AudioDeviceID`.
    /// Returns `nil` for nil/empty UID (meaning "use system default").
    public static func resolveDeviceID(uid: String?) -> AudioDeviceID? {
        guard let uid, !uid.isEmpty else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let uidCF = uid as CFString

        let status = withUnsafePointer(to: uidCF) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                UnsafeMutableRawPointer(mutating: uidPtr),
                &size,
                &deviceID
            )
        }

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    // MARK: - Test Utilities

    /// Generate a sine wave test tone buffer.
    public static func generateTestTone(
        sampleRate: Double = 44100,
        duration: Double = 1.5,
        frequency: Double = 440
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard let data = buffer.floatChannelData?[0] else { return nil }

        let fadeFrames = Int(sampleRate * 0.05) // 50ms fade-in/out
        let totalFrames = Int(frameCount)

        for i in 0..<totalFrames {
            var sample = Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate))

            // Fade-in
            if i < fadeFrames {
                sample *= Float(i) / Float(fadeFrames)
            }
            // Fade-out
            let remaining = totalFrames - 1 - i
            if remaining < fadeFrames {
                sample *= Float(remaining) / Float(fadeFrames)
            }

            data[i] = sample * 0.3 // -10dB to avoid being too loud
        }

        return buffer
    }

    /// Compute RMS level of a PCM buffer.
    public static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sumSquares: Float = 0
        for i in 0..<count {
            let sample = data[i]
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / Float(count))
    }

    // MARK: - Device Enumeration

    private func refreshDevices() {
        let devices = Self.enumerateDevices()
        let inputs = devices.filter(\.hasInput)
        let outputs = devices.filter(\.hasOutput)

        if Thread.isMainThread {
            self.inputDevices = inputs
            self.outputDevices = outputs
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.inputDevices = inputs
                self?.outputDevices = outputs
            }
        }
    }

    private static func enumerateDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard let uid = getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
            else { return nil }

            let hasInput = hasStreams(deviceID, scope: kAudioObjectPropertyScopeInput)
            let hasOutput = hasStreams(deviceID, scope: kAudioObjectPropertyScopeOutput)

            guard hasInput || hasOutput else { return nil }

            return AudioDevice(
                id: deviceID,
                uniqueID: uid,
                name: name,
                hasInput: hasInput,
                hasOutput: hasOutput
            )
        }
    }

    private static func getStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size = UInt32(MemoryLayout<CFString?>.size)
        let ptr = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<CFString?>.size,
            alignment: MemoryLayout<CFString?>.alignment
        )
        defer { ptr.deallocate() }
        ptr.initializeMemory(as: CFString?.self, repeating: nil, count: 1)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        guard status == noErr else { return nil }

        guard let cfString = ptr.assumingMemoryBound(to: CFString?.self).pointee else { return nil }
        return cfString as String
    }

    private static func hasStreams(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    // MARK: - Hot-Plug Observation

    private func installHotPlugListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
        }
        listenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeHotPlugListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        listenerBlock = nil
    }
}
