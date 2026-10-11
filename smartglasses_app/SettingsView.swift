//
//  SettingsView.swift
//  smartglasses_app
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    // Stored in UserDefaults since this is a prototype (move to Keychain for production)
    @AppStorage(SettingsKey.apiKey) private var apiKey = ""
    @AppStorage(SettingsKey.model) private var model = SettingsKey.defaultModel
    @AppStorage(SettingsKey.glassesHost) private var glassesHost = SettingsKey.defaultGlassesHost
    @AppStorage(SettingsKey.wakeWord) private var wakeWord = SettingsKey.defaultWakeWord
    @AppStorage(SettingsKey.speechLocale) private var speechLocale = SettingsKey.defaultSpeechLocale
    @AppStorage(SettingsKey.ocrLanguage) private var ocrLanguage = SettingsKey.defaultOCRLanguage

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenAI") {
                    SecureField("API Key (sk-...)", text: $apiKey)
                    TextField("Model", text: $model)
                }
                Section {
                    TextField("Host", text: $glassesHost)
                } header: {
                    Text("Glasses")
                } footer: {
                    Text("Address of the Raspberry Pi running app_shoot.py, e.g. raspberrypi.local:5000")
                }
                Section {
                    TextField("Wake word", text: $wakeWord)
                    Picker("Language", selection: $speechLocale) {
                        Text("English").tag("en-US")
                        Text("日本語").tag("ja-JP")
                    }
                } header: {
                    Text("Wake Word")
                } footer: {
                    Text("Say this to the glasses to take a photo and ask about it. Speech is recognized on this device, nothing is sent until the wake word is heard. Changes apply after toggling listening off and on.")
                }
                Section {
                    Picker("Language", selection: $ocrLanguage) {
                        ForEach(TextRecognizer.languages, id: \.id) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                } header: {
                    Text("Text Recognition (OCR)")
                } footer: {
                    Text("Text in each photo is read on this device and sent with the photo to help the AI read it accurately. English is also recognized alongside the selected language.")
                }
            }
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
