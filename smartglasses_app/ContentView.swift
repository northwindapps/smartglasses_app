//
//  ContentView.swift
//  smartglasses_app
//
//  Created by yano on 2026/10/05.
//

import SwiftUI

struct ContentView: View {
    @State private var store = ChatStore()
    @State private var listener = WakeWordListener()
    @State private var showSettings = false
    @AppStorage(SettingsKey.listening) private var listeningEnabled = true
    @AppStorage(SettingsKey.wakeWord) private var wakeWord = SettingsKey.defaultWakeWord
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            messageList
                .safeAreaInset(edge: .bottom) { composer }
                .navigationTitle("Glasses Chat")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Chat", systemImage: "square.and.pencil") { store.newChat() }
                            .disabled(store.messages.isEmpty)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    }
                }
                .sheet(isPresented: $showSettings) { SettingsView() }
                // Listen to the glasses mic only while the app is in the foreground
                .onChange(of: scenePhase, initial: true) { updateListening() }
                .onChange(of: listeningEnabled) { updateListening() }
                .alert("Error", isPresented: Binding(
                    get: { store.errorMessage != nil },
                    set: { if !$0 { store.errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(store.errorMessage ?? "")
                }
        }
    }

    private func updateListening() {
        if listeningEnabled && scenePhase == .active {
            listener.start { transcript in await store.handleWake(transcript: transcript) }
        } else {
            listener.stop()
        }
    }

    private var listeningStatus: some View {
        Button {
            listeningEnabled.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: !listeningEnabled ? "mic.slash" : listener.isConnected ? "waveform" : "wifi.exclamationmark")
                    .foregroundStyle(!listeningEnabled ? Color.secondary : listener.isConnected ? .green : .orange)
                Text(!listeningEnabled ? "Wake word off"
                     : listener.status ?? (!listener.isConnected ? "Connecting to glasses…"
                     : listener.lastHeard.isEmpty ? "Listening for “\(wakeWord)”"
                     : "Heard: \(listener.lastHeard)"))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Turns wake word listening on or off")
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.messages.isEmpty {
                    ContentUnavailableView("Look at something",
                                           systemImage: "eyeglasses",
                                           description: Text("Tap the glasses button to take a photo, then ask about it."))
                        .padding(.top, 120)
                }
                LazyVStack(spacing: 16) {
                    ForEach(store.messages) { message in
                        MessageRow(message: message,
                                   isTyping: store.isResponding && message.id == store.messages.last?.id)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.last?.text) {
                if let last = store.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: store.messages.count) {
                if let last = store.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            listeningStatus

            if let data = store.pendingImage, let image = Image(jpegData: data) {
                HStack(alignment: .top, spacing: 10) {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay(alignment: .topTrailing) {
                            Button("Remove", systemImage: "xmark.circle.fill") { store.pendingImage = nil }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .offset(x: 6, y: -6)
                        }
                    if let text = store.pendingText {
                        OCRText(text: text, lineLimit: 4)
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    Task { await store.captureFromGlasses() }
                } label: {
                    if store.isCapturing {
                        ProgressView().frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "eyeglasses")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.isCapturing)
                .accessibilityLabel("Capture from glasses")

                TextField("Ask anything", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { store.send() }
                    .padding(.vertical, 8)

                if store.isResponding {
                    Button("Stop", systemImage: "stop.circle.fill") { store.stop() }
                        .labelStyle(.iconOnly)
                        .font(.title)
                        .buttonStyle(.plain)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { store.send() }
                        .labelStyle(.iconOnly)
                        .font(.title)
                        .buttonStyle(.plain)
                        .foregroundStyle(store.canSend ? Color.accentColor : .secondary)
                        .disabled(!store.canSend)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .background(.background.secondary, in: .rect(cornerRadius: 24))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isTyping: Bool

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if let data = message.imageData, let image = Image(jpegData: data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .clipShape(.rect(cornerRadius: 16))
                }
                if let text = message.ocrText {
                    OCRText(text: text, lineLimit: nil)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.background.secondary, in: .rect(cornerRadius: 20))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)

        case .assistant:
            Group {
                if message.text.isEmpty && isTyping {
                    ProgressView()
                } else {
                    Text(LocalizedStringKey(message.text))   // Render simple Markdown such as **bold**
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// Text read from a photo by on-device OCR
private struct OCRText: View {
    let text: String
    let lineLimit: Int?

    var body: some View {
        Label {
            Text(text)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "text.viewfinder")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Text in photo: \(text)")
    }
}

extension Image {
    init?(jpegData data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #else
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #endif
    }
}

#Preview {
    ContentView()
}
