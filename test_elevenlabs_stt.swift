#!/usr/bin/env swift

// Quick standalone test for ElevenLabs Scribe v2 Realtime WebSocket STT.
// Usage: swift test_elevenlabs_stt.swift <API_KEY>
//
// This sends a short sine-wave tone (simulating speech) and checks:
// 1. WebSocket connects successfully
// 2. session_started is received
// 3. Audio chunks are accepted
// 4. committed_transcript is received after commit

import Foundation

guard CommandLine.arguments.count >= 2 else {
    print("Usage: swift test_elevenlabs_stt.swift <API_KEY>")
    exit(1)
}

let apiKey = CommandLine.arguments[1]
let modelId = "scribe_v2_realtime"
let languageCode = "en"

// Build WebSocket URL
var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
components.queryItems = [
    URLQueryItem(name: "model_id", value: modelId),
    URLQueryItem(name: "language_code", value: languageCode),
    URLQueryItem(name: "commit_strategy", value: "manual"),
    URLQueryItem(name: "audio_format", value: "pcm_16000"),
]
let url = components.url!

var request = URLRequest(url: url)
request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

print("[1/5] Connecting to \(url.absoluteString)")

let session = URLSession(configuration: .default)
let ws = session.webSocketTask(with: request)
ws.resume()

let semaphore = DispatchSemaphore(value: 0)
var receivedSessionStarted = false
var receivedTranscript = false
var lastError: String?

// Receive loop
func receiveLoop() {
    ws.receive { result in
        switch result {
        case .success(let message):
            if case .string(let text) = message {
                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let messageType = json["message_type"] as? String {
                    switch messageType {
                    case "session_started":
                        print("[2/5] ✅ session_started received")
                        if let config = json["config"] {
                            print("      Config: \(config)")
                        }
                        receivedSessionStarted = true
                        semaphore.signal()

                    case "partial_transcript":
                        let t = json["text"] as? String ?? ""
                        if !t.isEmpty {
                            print("      Partial: \"\(t)\"")
                        }

                    case "committed_transcript", "committed_transcript_with_timestamps":
                        let t = json["text"] as? String ?? ""
                        print("[4/5] ✅ committed_transcript received: \"\(t)\"")
                        receivedTranscript = true
                        semaphore.signal()

                    case "error", "auth_error", "quota_exceeded", "rate_limited",
                         "input_error", "chunk_size_exceeded", "transcriber_error":
                        let err = json["error"] as? String ?? "unknown"
                        print("[ERR] ❌ Server error [\(messageType)]: \(err)")
                        lastError = err
                        semaphore.signal()
                        return // stop receiving

                    default:
                        print("      Message: \(messageType) -> \(text.prefix(200))")
                    }
                } else {
                    print("      Raw: \(text.prefix(200))")
                }
            }
            receiveLoop() // continue receiving

        case .failure(let error):
            print("[ERR] ❌ Receive failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            semaphore.signal()
        }
    }
}

receiveLoop()

// Wait for session_started (10s timeout)
let sessionResult = semaphore.wait(timeout: .now() + 10)
if sessionResult == .timedOut {
    print("[2/5] ❌ Timed out waiting for session_started")
    print("      This usually means:")
    print("      - API key is invalid")
    print("      - Network/firewall blocks WebSocket")
    print("      - xi-api-key header was not sent")
    ws.cancel(with: .normalClosure, reason: nil)
    exit(1)
}

if lastError != nil {
    ws.cancel(with: .normalClosure, reason: nil)
    exit(1)
}

guard receivedSessionStarted else {
    ws.cancel(with: .normalClosure, reason: nil)
    exit(1)
}

// Generate 1 second of 440Hz sine wave as Int16 PCM @ 16kHz
print("[3/5] Sending 1s of 440Hz test tone as PCM audio...")
let sampleRate = 16000
let duration = 1.0
let frequency = 440.0
let numSamples = Int(Double(sampleRate) * duration)
var pcmData = Data(capacity: numSamples * 2)

for i in 0..<numSamples {
    let t = Double(i) / Double(sampleRate)
    let value = sin(2.0 * .pi * frequency * t) * 0.5
    var sample = Int16(value * 32767)
    withUnsafeBytes(of: &sample) { pcmData.append(contentsOf: $0) }
}

// Send in chunks of 3200 bytes (100ms each)
let chunkSize = 3200
var offset = 0
var chunkCount = 0
while offset < pcmData.count {
    let end = min(offset + chunkSize, pcmData.count)
    let chunk = pcmData[offset..<end]
    let base64 = chunk.base64EncodedString()

    let msg: [String: Any] = [
        "message_type": "input_audio_chunk",
        "audio_base_64": base64,
        "commit": false,
    ]
    let jsonData = try! JSONSerialization.data(withJSONObject: msg)
    let jsonStr = String(data: jsonData, encoding: .utf8)!
    ws.send(.string(jsonStr)) { error in
        if let error {
            print("      Send error: \(error.localizedDescription)")
        }
    }
    offset = end
    chunkCount += 1
}
print("      Sent \(chunkCount) chunks (\(pcmData.count) bytes total)")

// Small delay to let server process audio before commit
Thread.sleep(forTimeInterval: 0.5)

// Send commit
print("      Sending commit...")
let commitMsg: [String: Any] = [
    "message_type": "input_audio_chunk",
    "audio_base_64": "",
    "commit": true,
]
let commitData = try! JSONSerialization.data(withJSONObject: commitMsg)
let commitStr = String(data: commitData, encoding: .utf8)!
ws.send(.string(commitStr)) { error in
    if let error {
        print("      Commit send error: \(error.localizedDescription)")
    }
}

// Wait for committed_transcript (15s timeout)
let commitResult = semaphore.wait(timeout: .now() + 15)
if commitResult == .timedOut {
    print("[4/5] ❌ Timed out waiting for committed_transcript")
    print("      Server accepted audio but never committed. Check model_id.")
    ws.cancel(with: .normalClosure, reason: nil)
    exit(1)
}

if lastError != nil {
    ws.cancel(with: .normalClosure, reason: nil)
    exit(1)
}

// Close
ws.cancel(with: .normalClosure, reason: nil)
print("[5/5] ✅ All checks passed! WebSocket STT integration is working.")
print("")
print("Summary:")
print("  session_started: \(receivedSessionStarted ? "✅" : "❌")")
print("  committed_transcript: \(receivedTranscript ? "✅" : "❌")")
