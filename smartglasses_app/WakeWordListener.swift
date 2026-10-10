//
//  WakeWordListener.swift
//  smartglasses_app
//

import AVFoundation
import Foundation
import Observation
import Speech

// メガネのマイク (/api/audio/stream) を端末内の音声認識 (SFSpeechRecognizer, オンデバイス) に流し続け、ウェイクワードを探す
@Observable
final class WakeWordListener {
    var isConnected = false
    var lastHeard = ""
    var status: String?   // 権限なし・未対応などのエラー

    // 話し終わり (この秒数だけ認識結果が変わらない) で 1 文とみなす
    static let pauseSeconds = 1.2
    // 認識タスクには長さの上限があるので、話していなくても定期的に作り直す
    static let maxTaskSeconds = 50.0

    // Pi から届く形式: 16kHz / mono / int16 → 認識には Float32 で渡す
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

    func start(onWake: @escaping (String) async -> Void) {
        guard task == nil else { return }
        task = Task { await run(onWake: onWake) }
    }

    func stop() {
        task?.cancel()
        task = nil
        endRecognition()
        isConnected = false
    }

    private func run(onWake: @escaping (String) async -> Void) async {
        while !Task.isCancelled {
            do {
                try await listen(onWake: onWake)
            } catch is CancellationError {
                break
            } catch {
                status = error.localizedDescription
                print("[speech] \(error)")
            }
            endRecognition()
            isConnected = false
            try? await Task.sleep(for: .seconds(2))   // Wi-Fi が落ちたら少し待って再接続
        }
    }

    private func listen(onWake: @escaping (String) async -> Void) async throws {
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

            // 話し終わったら 1 文として判定し、次の文のために認識を作り直す
            let now = Date()
            let paused = !transcript.isEmpty && now.timeIntervalSince(lastChange) > Self.pauseSeconds
            if paused || now.timeIntervalSince(taskStarted) > Self.maxTaskSeconds {
                let sentence = transcript
                startRecognition(wakeWord: wakeWord)
                if paused {
                    let isWake = Self.normalize(sentence).contains(Self.normalize(wakeWord))
                    print("[speech] heard: \"\(sentence)\"\(isWake ? " → WAKE" : "")")
                    if isWake { await onWake(sentence) }
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
        request.contextualStrings = [wakeWord]   // ウェイクワードを認識しやすくする

        generation += 1
        let current = generation
        transcript = ""
        taskStarted = Date()
        lastChange = Date()
        self.request = request
        // 結果は recognizer.queue (メインキュー) で届く
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
                // 無音が続くとタスクがエラーで終わる → 少し待って作り直す
                if ended {
                    var delay = 1.0
                    if let error = error as NSError?, !Self.isNoSpeech(error) {
                        let message = "Speech: \(error.localizedDescription)"
                        if message != self.status { print("[speech] \(error)") }   // 同じエラーは 1 回だけ出す
                        self.status = message
                        delay = 5   // 設定の問題 (音声入力オフなど) は直るまで待つ
                    }
                    self.retryAfter = Date().addingTimeInterval(delay)
                    self.endRecognition()
                }
            }
        }
    }

    // 無音でタスクが終わっただけのエラー (異常ではない)
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

    // "Hey, Glasses!" と "hey glasses" を同じとみなす (日本語もそのまま比較できる)
    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

private struct ListenerError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// Pi 側: 16kHz / mono / int16 の生 PCM を流し続ける
nonisolated enum AudioStream {
    static let chunkBytes = 3_200   // 0.1 秒ずつ認識に渡す

    // 接続できたら最初に空の Data を流す (接続の合図)
    static func chunks(host: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "http://\(host)/api/audio/stream") else { throw URLError(.badURL) }
                    // ストリームが 10 秒止まったら (Wi-Fi 切断など) タイムアウトして再接続
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
