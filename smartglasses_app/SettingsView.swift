//
//  SettingsView.swift
//  smartglasses_app
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    // プロトタイプなので UserDefaults に保存 (本番では Keychain に移す)
    @AppStorage(SettingsKey.apiKey) private var apiKey = ""
    @AppStorage(SettingsKey.model) private var model = SettingsKey.defaultModel
    @AppStorage(SettingsKey.glassesHost) private var glassesHost = SettingsKey.defaultGlassesHost
    @AppStorage(SettingsKey.wakeWord) private var wakeWord = SettingsKey.defaultWakeWord
    @AppStorage(SettingsKey.speechLocale) private var speechLocale = SettingsKey.defaultSpeechLocale

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
