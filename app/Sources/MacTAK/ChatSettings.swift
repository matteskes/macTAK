// ChatSettings.swift — the Settings window's Chat pane: ATAK 5.5's Chat
// Preferences (ChatPrefsFragment, chat_preferences.xml), with 5.5's words.
// So far its History Preferences' Clear History: asked first ("Are you sure
// you want to clear chat history?", Yes / No), then the history and user
// groups go (GeoChatService.clearMessageDB) and "Chat History deleted"
// shows as 5.5's short toast does, for 2 seconds.

import MacTAKComms
import SwiftUI

struct ChatSettings: View {
    @EnvironmentObject private var connections: ServerConnections
    @State private var confirming = false
    /// What 5.5 toasts after a clear, while it shows.
    @State private var toast: String?

    /// Toast.LENGTH_SHORT.
    private static let toastSeconds = 2.0

    var body: some View {
        Form {
            Section("History Preferences") {
                Button { confirming = true } label: {
                    VStack(alignment: .leading) {
                        Text("Clear History")
                        Text("Clear Chat History.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let toast { Text(toast).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .alert("Are you sure you want to clear chat history?", isPresented: $confirming) {
            Button("Yes", role: .destructive) { clearChatHistory() }
            Button("No", role: .cancel) {}
        }
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(Self.toastSeconds))   // cancelled: a newer toast replaced it
            if !Task.isCancelled { toast = nil }
        }
    }

    /// ChatPrefsFragment.clearChatHistory, its log lines included.
    private func clearChatHistory() {
        guard let chat = connections.chat else {
            NSLog("ChatPrefsFragment: Connected to NULL GeoChatService.")
            return
        }
        do {
            try chat.clearHistory()
            NSLog("ChatPrefsFragment: Cleared the Chat DB.")
            toast = "Chat History deleted"
        } catch {
            NSLog("ChatPrefsFragment: Error clearing chat message from Chat DB: \(error)")
        }
    }
}
