//
//  ChatStore.swift
//  smartglasses_app
//

import Foundation
import Observation

struct ChatMessage: Identifiable {
    enum Role: String { case user, assistant }

    let id = UUID()
    let role: Role
    var text: String
    var imageData: Data?
}

enum SettingsKey {
    static let apiKey = "openai_api_key"
    static let model = "openai_model"
    static let glassesHost = "glasses_host"
    static let wakeWord = "wake_word"
    static let listening = "listening"
    static let speechLocale = "speech_locale"

    static let defaultModel = "gpt-5-mini"
    static let defaultGlassesHost = "raspberrypi.local:5000"
    static let defaultWakeWord = "hey glasses"
    static let defaultSpeechLocale = "en-US"
}

@Observable
final class ChatStore {
    var messages: [ChatMessage] = []
    var draft = ""
    var pendingImage: Data?
    var isCapturing = false
    var isResponding = false
    var errorMessage: String?

    private var responseTask: Task<Void, Never>?

    var canSend: Bool {
        !isResponding && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil)
    }

    // メガネのカメラで撮影して、次のメッセージに添付する
    func captureFromGlasses() async {
        isCapturing = true
        defer { isCapturing = false }
        let host = UserDefaults.standard.string(forKey: SettingsKey.glassesHost) ?? SettingsKey.defaultGlassesHost
        do {
            pendingImage = try await GlassesClient.capture(host: host)
        } catch {
            errorMessage = "Glasses: \(error.localizedDescription)"
        }
    }

    // ウェイクワードの後がこれだけなら Pi をシャットダウン ("shut down" は normalize で "shutdown" になる)
    static let shutdownCommands: Set<String> = ["halt", "stop", "shutdown", "poweroff"]

    // ウェイクワード検出 → 撮影して、聞き取った文と一緒に送る
    func handleWake(transcript: String) async {
        if isShutdownCommand(transcript) {
            await shutdownGlasses()
            return
        }
        guard !isResponding, !isCapturing else { return }
        await captureFromGlasses()
        guard pendingImage != nil else { return }
        draft = transcript
        send()
    }

    func shutdownGlasses() async {
        let host = UserDefaults.standard.string(forKey: SettingsKey.glassesHost) ?? SettingsKey.defaultGlassesHost
        do {
            try await GlassesClient.shutdown(host: host)
            messages.append(ChatMessage(role: .assistant, text: "Shutting down the glasses."))
        } catch {
            errorMessage = "Glasses: \(error.localizedDescription)"
        }
    }

    // "Hey glasses, halt." → true / "Hey glasses, what does this stop sign say?" → false
    private func isShutdownCommand(_ transcript: String) -> Bool {
        let wakeWord = UserDefaults.standard.string(forKey: SettingsKey.wakeWord) ?? SettingsKey.defaultWakeWord
        let text = WakeWordListener.normalize(transcript)
        guard let range = text.range(of: WakeWordListener.normalize(wakeWord)) else { return false }
        return Self.shutdownCommands.contains(String(text[range.upperBound...]))
    }

    func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(ChatMessage(role: .user,
                                    text: text.isEmpty ? "What do you see?" : text,
                                    imageData: pendingImage))
        draft = ""
        pendingImage = nil
        respond()
    }

    func stop() {
        responseTask?.cancel()
    }

    func newChat() {
        stop()
        messages = []
        draft = ""
        pendingImage = nil
    }

    private func respond() {
        let defaults = UserDefaults.standard
        let apiKey = defaults.string(forKey: SettingsKey.apiKey) ?? ""
        let model = defaults.string(forKey: SettingsKey.model).flatMap { $0.isEmpty ? nil : $0 } ?? SettingsKey.defaultModel
        guard !apiKey.isEmpty else {
            errorMessage = "Set your OpenAI API key in Settings."
            return
        }

        let history = messages
        messages.append(ChatMessage(role: .assistant, text: ""))
        let index = messages.count - 1
        isResponding = true

        responseTask = Task {
            defer { isResponding = false }
            do {
                for try await delta in OpenAIClient.stream(apiKey: apiKey, model: model, messages: history) {
                    messages[index].text += delta
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            if messages[index].text.isEmpty {
                messages.remove(at: index)
            }
        }
    }
}

enum GlassesClient {
    // Pi 側 app_shoot.py の /api/capture が JPEG を返す
    static func capture(host: String) async throws -> Data {
        guard let url = URL(string: "http://\(host)/api/capture") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // Pi 側 /api/shutdown → 応答を返してから sudo halt
    static func shutdown(host: String) async throws {
        guard let url = URL(string: "http://\(host)/api/shutdown") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}

enum OpenAIClient {
    struct APIError: LocalizedError {
        let errorDescription: String?
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]
    }

    static let systemPrompt = """
    You are an assistant for a user wearing camera smart glasses. \
    Images come from the glasses' camera (grayscale) and show what the user is looking at. \
    Messages may be speech transcripts that start with the wake word; if the user only said the wake word, \
    briefly describe what is in the image. Answer concisely and conversationally.
    """

    static func stream(apiKey: String, model: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "stream": true,
                        "messages": [["role": "system", "content": systemPrompt]] + messages.map(payload),
                    ])

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw APIError(errorDescription: "OpenAI \(http.statusCode): \(errorText(body))")
                    }

                    // Server-Sent Events: "data: {json}" ... "data: [DONE]"
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = line.dropFirst(6)
                        if json == "[DONE]" { break }
                        let chunk = try JSONDecoder().decode(StreamChunk.self, from: Data(json.utf8))
                        if let text = chunk.choices.first?.delta.content, !text.isEmpty {
                            continuation.yield(text)
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

    private static func payload(_ message: ChatMessage) -> [String: Any] {
        guard let image = message.imageData else {
            return ["role": message.role.rawValue, "content": message.text]
        }
        return [
            "role": message.role.rawValue,
            "content": [
                ["type": "text", "text": message.text],
                ["type": "image_url",
                 "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]],
            ],
        ]
    }

    private static func errorText(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return body }
        return message
    }
}
