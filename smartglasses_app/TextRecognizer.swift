//
//  TextRecognizer.swift
//  smartglasses_app
//

import Foundation
import Vision

// On-device OCR (Vision). Runs on the photo from the glasses; nothing is sent anywhere
enum TextRecognizer {
    // Shown in Settings; tag = Vision language identifier
    static let languages: [(name: String, id: String)] = [
        ("English", "en-US"),
        ("日本語", "ja-JP"),
        ("中文 (简体)", "zh-Hans"),
        ("Deutsch", "de-DE"),
        ("Français", "fr-FR"),
        ("Español", "es-ES"),
    ]

    // Returns the recognized lines top to bottom, or nil if there is no text
    static func recognize(_ jpeg: Data, language: String) async throws -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Keep English as a fallback so mixed text (e.g. Japanese signs with English words) still reads
        let ids = language == "en-US" ? [language] : [language, "en-US"]
        request.recognitionLanguages = ids.map { Locale.Language(identifier: $0) }

        let observations = try await request.perform(on: jpeg)
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
