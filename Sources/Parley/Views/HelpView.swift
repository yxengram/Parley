import AppKit
import SwiftUI

/// Offline help (Help > Parley Help). Plain local text; no links are loaded.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Parley Help").font(.title2.weight(.semibold))
                        Text("A private chat client for OpenAI-compatible APIs.")
                            .foregroundStyle(.secondary)
                    }
                }

                section("Getting started", "server.rack", [
                    "Open Settings (⌘,) > Providers and add a server. The base URL includes the version path, for example http://localhost:1234/v1 for LM Studio or https://api.openai.com/v1.",
                    "API keys are stored in your login Keychain and never synced. Local servers usually need no key.",
                    "Use Test Connection to load the server's model list. A new chat uses the provider's default model, or the first model the server lists. Change it with the model menu in the toolbar, which also accepts a custom model ID.",
                ])

                section("Messages", "bubble.left.and.text.bubble.right", [
                    "Enter sends, Shift-Enter adds a line. Attach images or text files with the paperclip, by drag and drop, or by pasting.",
                    "Hover over a message, or right-click it, to Copy, Edit & Resend (your messages), Regenerate (replies), Fork from Here or Roll Back to Here.",
                    "Edit & Resend puts the message back in the composer. Nothing changes until you send it; Esc cancels. ↑ in an empty composer edits your last message.",
                    "Fork copies the conversation up to that message into a new file. Roll Back deletes everything after the message.",
                    "Shortcuts: ⌘R regenerates the last reply, ⇧⌘C copies it, ⇧⌘E edits your last message, ⌘. or Esc stops a reply, ⌘I opens the conversation settings.",
                ])

                section("Thinking", "brain", [
                    "Reasoning from models that send it (reasoning_content, reasoning, or <think> tags) is shown in a collapsible section with how long the model thought. It is never sent back to the server.",
                    "Reasoning Effort “None (no thinking)” (Conversation Settings, ⌘I) asks the server not to think. Not every server or model supports it; a note under the reply says so when Parley can tell it was refused or ignored.",
                ])

                section("Encryption", "lock", [
                    "A conversation can be encrypted when you create it, or later with Conversation > Encrypt…. The whole file is encrypted with AES-256-GCM using a key derived from your password, and decrypted only in memory.",
                    "There is no way to recover a forgotten password.",
                    "Encrypting an existing conversation overwrites its file in place. On SSDs this is not a secure erase; older copies may remain in backups or snapshots.",
                    "Lock (⌘L) saves the conversation and removes the decrypted copy and key from memory.",
                ])

                section("Where files live", "folder", [
                    "Each conversation is one JSON file named by a random ID, by default in ~/Library/Application Support/Parley/Conversations (not synced by iCloud). You can change the default folder in Settings > General, and choose a folder for each new chat.",
                    "Conversation > Reveal in Finder shows a conversation's file. Move to Trash moves it to the Trash; it is not deleted permanently.",
                ])

                section("Privacy", "hand.raised", [
                    "Parley only contacts the API endpoints you configure. No telemetry, no analytics, no remote images.",
                    "The Copy buttons keep text off Universal Clipboard. Text you select and copy with ⌘C uses the normal clipboard.",
                ])
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 480, minHeight: 400)
    }

    private func section(_ title: String, _ symbol: String, _ paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
            ForEach(paragraphs, id: \.self) { p in
                Text(p)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
