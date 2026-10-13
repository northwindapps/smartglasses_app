//
//  WakeWordListener.swift
//  smartglasses_app
//

import AVFoundation
import Foundation
import Observation
import Speech

// Continuously feed the glasses mic (/api/audio/stream) into on-device speech recognition (SFSpeechRecognizer) to find the wake word
@Observable
final class WakeWordListener {
    var isConnected = false
    var lastHeard = ""
    var status: String?   // Errors such as missing permission or unsupported device

    // Treat it as one sentence once speech ends (recognition result unchanged for this many seconds)
    static let pauseSeconds = 1.2
    // Recognition tasks have a length limit, so recreate them periodically even when no one is speaking
    static let maxTaskSeconds = 50.0

    // Format received from the Pi: 16kHz / mono / int16 -> passed to recognition as Float32
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var task: Task<Void, Never>?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var generation = 0
    private var taskStarted = Date()
    private var transcript = ""
    private var lastChange = Date()
    private var retryAfter = Date()

    func start(onSentence: @escaping (String, Bool) async -> Void) {
        guard task == nil else { return }
        task = Task { await run(onSentence: onSentence) }
    }

    func stop() {
        task?.cancel()
        task = nil
        endRecognition()
        isConnected = false
    }

    private func run(onSentence: @escaping (String, Bool) async -> Void) async {
        while !Task.isCancelled {
            do {
                try await listen(onSentence: onSentence)
            } catch is CancellationError {
                break
            } catch {
                status = error.localizedDescription
                print("[speech] \(error)")
            }
            endRecognition()
            isConnected = false
            try? await Task.sleep(for: .seconds(2))   // If Wi-Fi drops, wait a bit and reconnect
        }
    }

    private func listen(onSentence: @escaping (String, Bool) async -> Void) async throws {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: SettingsKey.glassesHost) ?? SettingsKey.defaultGlassesHost
        let wakeWord = defaults.string(forKey: SettingsKey.wakeWord) ?? SettingsKey.defaultWakeWord
        let localeID = defaults.string(forKey: SettingsKey.speechLocale) ?? SettingsKey.defaultSpeechLocale

        guard await Self.requestAuthorization() == .authorized else {
            throw ListenerError("Allow Speech Recognition in Settings to use the wake word.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              recognizer.supportsOnDeviceRecognition else {
            throw ListenerError("On-device speech recognition for \(localeID) isn't available on this device.")
        }
        self.recognizer = recognizer

        for try await pcm in AudioStream.chunks(host: host) {
            isConnected = true
            if recognitionTask == nil, Date() > retryAfter { startRecognition(wakeWord: wakeWord) }
            if !pcm.isEmpty, let buffer = makeBuffer(pcm) { request?.append(buffer) }

            // When speech ends, evaluate it as one sentence and recreate recognition for the next one
            let now = Date()
            let paused = !transcript.isEmpty && now.timeIntervalSince(lastChange) > Self.pauseSeconds
            if paused || now.timeIntervalSince(taskStarted) > Self.maxTaskSeconds {
                let sentence = transcript
                startRecognition(wakeWord: wakeWord)
                if paused {
                    let isWake = Self.normalize(sentence).contains(Self.normalize(wakeWord))
                    print("[speech] heard: \"\(sentence)\"\(isWake ? " → WAKE" : "")")
                    await onSentence(sentence, isWake)   // Non-wake sentences matter only while the action popup is open
                }
            }
        }
    }

    private func startRecognition(wakeWord: String) {
        endRecognition()
        guard let recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = [wakeWord] + GlassesAction.speechHints   // Make the wake word and popup options easier to recognize

        generation += 1
        let current = generation
        transcript = ""
        taskStarted = Date()
        lastChange = Date()
        self.request = request
        // Results arrive on recognizer.queue (the main queue)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = error != nil || result?.isFinal == true
            MainActor.assumeIsolated {
                guard let self, current == self.generation else { return }
                if let text, text != self.transcript {
                    self.status = nil
                    self.transcript = text
                    self.lastChange = Date()
                    if !text.isEmpty { self.lastHeard = text }
                }
                // Continued silence ends the task with an error -> wait a bit and recreate it
                if ended {
                    var delay = 1.0
                    if let error = error as NSError?, !Self.isNoSpeech(error) {
                        let message = "Speech: \(error.localizedDescription)"
                        if message != self.status { print("[speech] \(error)") }   // Print the same error only once
                        self.status = message
                        delay = 5   // For settings problems (e.g. dictation turned off), wait until fixed
                    }
                    self.retryAfter = Date().addingTimeInterval(delay)
                    self.endRecognition()
                }
            }
        }
    }

    // Error that just means the task ended due to silence (not a real problem)
    private static func isNoSpeech(_ error: NSError) -> Bool {
        error.domain == "kAFAssistantErrorDomain" && error.code == 1110
    }

    private func endRecognition() {
        generation += 1
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
    }

    private func makeBuffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for i in 0..<frames {
                channel[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
        return buffer
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    // Treat "Hey, Glasses!" and "hey glasses" as the same (Japanese text compares as-is too)
    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

private struct ListenerError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// Pi side: continuously streams raw 16kHz / mono / int16 PCM
nonisolated enum AudioStream {
    static let chunkBytes = 3_200   // Pass 0.1 seconds at a time to recognition

    // Once connected, first send an empty Data (signals the connection is up)
    static func chunks(host: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "http://\(host)/api/audio/stream") else { throw URLError(.badURL) }
                    // If the stream stalls for 10 seconds (e.g. Wi-Fi drop), time out and reconnect
                    let request = URLRequest(url: url, timeoutInterval: 10)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    continuation.yield(Data())

                    var buffer = Data(capacity: chunkBytes)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count == chunkBytes {
                            continuation.yield(buffer)
                            buffer = Data(capacity: chunkBytes)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
