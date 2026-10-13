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
    var ocrText: String?
}

enum SettingsKey {
    static let apiKey = "openai_api_key"
    static let model = "openai_model"
    static let glassesHost = "glasses_host"
    static let wakeWord = "wake_word"
    static let listening = "listening"
    static let speechLocale = "speech_locale"
    static let ocrLanguage = "ocr_language"

    static let defaultModel = "gpt-5-mini"
    static let defaultGlassesHost = "raspberrypi.local:5000"
    static let defaultWakeWord = "hey glasses"
    static let defaultSpeechLocale = "en-US"
    static let defaultOCRLanguage = "en-US"
}

// What the user can ask for after the wake word, by voice or from the popup
enum GlassesAction: String, CaseIterable, Identifiable {
    case photo, translate, summarize, shutdown

    var id: Self { self }

    var title: String {
        switch self {
        case .photo: "Take Photo"
        case .translate: "Translate"
        case .summarize: "Summarize"
        case .shutdown: "Shut Down Glasses"
        }
    }

    // Spoken words that pick this action (matched inside the normalized sentence)
    private var keywords: [String] {
        switch self {
        case .photo: ["photo", "picture", "capture", "写真", "撮影", "撮って"]
        case .translate: ["translat", "翻訳", "訳して"]
        case .summarize: ["summar", "要約", "まとめ"]
        case .shutdown: []   // Only an exact match (see ChatStore.shutdownCommands), never "stop sign"
        }
    }

    // Word to say for this option while the popup is open
    var spoken: String {
        switch self {
        case .photo: "photo"
        case .translate: "translate"
        case .summarize: "summary"
        case .shutdown: "shut down"
        }
    }

    // Hints for the speech recognizer so short command words are caught reliably
    static let speechHints = allCases.map(\.spoken) + ["cancel", "picture", "summarize"]

    static func match(normalized text: String) -> GlassesAction? {
        if ChatStore.shutdownCommands.contains(text) { return .shutdown }
        return allCases.first { action in action.keywords.contains { text.contains($0) } }
    }
}

@Observable
final class ChatStore {
    var messages: [ChatMessage] = []
    var draft = ""
    var pendingImage: Data? {
        didSet { if pendingImage == nil { pendingText = nil } }   // Removing the photo also drops its OCR text
    }
    var pendingText: String?   // OCR result for pendingImage
    var isCapturing = false
    var isResponding = false
    var errorMessage: String?
    var showActions = false   // Popup shown after the bare wake word

    private var responseTask: Task<Void, Never>?
    private var actionsTimeout: Task<Void, Never>?
    private var pendingQuestion = ""   // Sentence said with the wake word, used if Take Photo is picked

    // Close the popup if nothing is picked within this time
    static let actionsTimeoutSeconds = 15.0
    static let cancelWords = ["cancel", "nevermind", "close", "キャンセル", "やめ"]

    var canSend: Bool {
        !isResponding && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil)
    }

    // Take a photo with the glasses camera, run OCR on it, and attach both to the next message
    func captureFromGlasses() async {
        isCapturing = true
        defer { isCapturing = false }
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: SettingsKey.glassesHost) ?? SettingsKey.defaultGlassesHost
        let language = defaults.string(forKey: SettingsKey.ocrLanguage) ?? SettingsKey.defaultOCRLanguage
        let image: Data
        do {
            image = try await GlassesClient.capture(host: host)
        } catch {
            errorMessage = "Glasses: \(error.localizedDescription)"
            return
        }
        pendingImage = image
        pendingText = nil
        // OCR failing shouldn't block the photo; the LLM can still read the image itself
        do {
            pendingText = try await TextRecognizer.recognize(image, language: language)
        } catch {
            print("[ocr] \(error)")
        }
    }

    // If this is all that follows the wake word, shut down the Pi ("shut down" becomes "shutdown" via normalize)
    static let shutdownCommands: Set<String> = ["halt", "stop", "shutdown", "poweroff", "シャットダウン", "電源オフ"]

    // Every sentence the glasses mic heard. Acted on only when it has the wake word, or while the popup is open
    //   "Hey glasses."                       -> popup with options
    //   "Hey glasses, translate this."        -> translate right away
    //   "Hey glasses, what does this say?"    -> popup; Take Photo uses the sentence as the question
    //   (popup open) "Summary."               -> summarize
    func handleHeard(_ transcript: String, isWake: Bool) async {
        if isWake {
            let rest = afterWakeWord(transcript)
            if Self.shutdownCommands.contains(rest) {
                await perform(.shutdown)
                return
            }
            guard !isCapturing, !isResponding else { return }
            switch GlassesAction.match(normalized: rest) {
            case .translate?: await perform(.translate)
            case .summarize?: await perform(.summarize)
            default: openActions(question: rest.isEmpty ? "" : transcript)
            }
        } else if showActions {
            let text = WakeWordListener.normalize(transcript)
            if Self.cancelWords.contains(where: text.contains) {
                closeActions()
            } else if let action = GlassesAction.match(normalized: text) {
                await perform(action)
            }
        }
    }

    func perform(_ action: GlassesAction) async {
        closeActions()
        switch action {
        case .photo: await askAboutPhoto(question: pendingQuestion)
        case .translate, .summarize: draftFromPhoto(action)
        case .shutdown: await shutdownGlasses()
        }
    }

    private func openActions(question: String) {
        pendingQuestion = question
        showActions = true
        actionsTimeout?.cancel()
        actionsTimeout = Task {
            try? await Task.sleep(for: .seconds(Self.actionsTimeoutSeconds))
            if !Task.isCancelled { showActions = false }
        }
    }

    private func closeActions() {
        actionsTimeout?.cancel()
        showActions = false
    }

    // Take a photo and put it in the composer with the question (the user taps Send)
    private func askAboutPhoto(question: String) async {
        guard !isCapturing else { return }
        await captureFromGlasses()
        guard pendingImage != nil else { return }
        draft = question
    }

    // Translate / summarize the text in front of the user and paste the result into the text field
    private func draftFromPhoto(_ action: GlassesAction) {
        guard !isCapturing, !isResponding, let (apiKey, model) = openAIConfig() else { return }
        let english = !(UserDefaults.standard.string(forKey: SettingsKey.speechLocale) ?? SettingsKey.defaultSpeechLocale).hasPrefix("ja")
        let language = english ? "English" : "Japanese"
        let instruction = action == .translate
            ? "Translate all the text in this image into \(language). If it is already in \(language), translate it into \(english ? "Japanese" : "English") instead. Output only the translation."
            : "Summarize the text in this image in \(language) in a few short lines. Output only the summary."

        draft = ""
        isResponding = true
        responseTask = Task {
            defer { isResponding = false }
            await captureFromGlasses()
            guard let image = pendingImage else { return }
            let request = ChatMessage(role: .user, text: instruction, imageData: image, ocrText: pendingText)
            do {
                for try await delta in OpenAIClient.stream(apiKey: apiKey, model: model, messages: [request],
                                                           systemPrompt: OpenAIClient.draftPrompt) {
                    draft += delta
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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

    // "Hey glasses, halt." → "halt" / "Hey glasses." → "" (normalized)
    private func afterWakeWord(_ transcript: String) -> String {
        let wakeWord = UserDefaults.standard.string(forKey: SettingsKey.wakeWord) ?? SettingsKey.defaultWakeWord
        let text = WakeWordListener.normalize(transcript)
        guard let range = text.range(of: WakeWordListener.normalize(wakeWord)) else { return text }
        return String(text[range.upperBound...])
    }

    private func openAIConfig() -> (apiKey: String, model: String)? {
        let defaults = UserDefaults.standard
        let apiKey = defaults.string(forKey: SettingsKey.apiKey) ?? ""
        let model = defaults.string(forKey: SettingsKey.model).flatMap { $0.isEmpty ? nil : $0 } ?? SettingsKey.defaultModel
        guard !apiKey.isEmpty else {
            errorMessage = "Set your OpenAI API key in Settings."
            return nil
        }
        return (apiKey, model)
    }

    func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(ChatMessage(role: .user,
                                    text: text.isEmpty ? "What do you see?" : text,
                                    imageData: pendingImage,
                                    ocrText: pendingText))
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
        guard let (apiKey, model) = openAIConfig() else { return }

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
    // /api/capture in app_shoot.py on the Pi returns a JPEG
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

    // /api/shutdown on the Pi -> replies first, then runs sudo halt
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
    briefly describe what is in the image. \
    An image may come with on-device OCR text; use it to read text accurately, but trust the image if they disagree. \
    Answer concisely and conversationally.
    """

    // For Translate / Summarize: the result goes straight into the text field
    static let draftPrompt = """
    You read text from photos taken by camera smart glasses (grayscale). \
    An image may come with on-device OCR text; use it to read text accurately, but trust the image if they disagree. \
    Follow the instruction exactly. Plain text only: no Markdown, no preamble.
    """

    static func stream(apiKey: String, model: String, messages: [ChatMessage],
                       systemPrompt: String = OpenAIClient.systemPrompt) -> AsyncThrowingStream<String, Error> {
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
        var content: [[String: Any]] = [
            ["type": "text", "text": message.text],
            ["type": "image_url",
             "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())",
                           "detail": "high"]],   // don't let OpenAI downscale (small text matters)
        ]
        if let ocr = message.ocrText {
            content.append(["type": "text", "text": "OCR text from the image (may contain errors):\n\(ocr)"])
        }
        return ["role": message.role.rawValue, "content": content]
    }

    private static func errorText(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return body }
        return message
    }
}
