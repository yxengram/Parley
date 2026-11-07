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

                section("Tools (MCP)", "wrench.and.screwdriver", [
                    "Parley can connect to MCP servers you add in Settings > MCP, by a local command or a remote URL, or by pasting a config from another MCP client. It offers their tools to the model, runs the calls the model makes, and sends the results back until the model answers.",
                    "Turn servers on for a conversation with the wrench button next to the paperclip (⇧⌘T). Nothing starts until you send a message in a conversation that uses the server, or press Connect in Settings. Turning a server off for a chat does not stop it: it runs until you press Stop in Settings or quit.",
                    "Every call asks first, with the exact arguments. Deny, Allow Once, or Always Allow This Tool, which lasts until the tool's definition, or the server's command, arguments, URL, working folder or PATH, changes. Revoke it in Settings > MCP, even while the server is stopped. Stop (Esc or ⌘.) cancels a running call.",
                    "Tool results stay in the conversation, encrypted when the conversation is. They are sent again with every message, like images. Regenerate does not undo what a tool did, and the model may run it again.",
                    "A local server is a program that runs on your Mac with your permissions, so add only servers you trust. Tool names, descriptions and parameters go to the model's provider with every request, tool or no tool call; arguments and results go to the server and to the model's provider. npx and uvx contact their package registries themselves.",
                    "Parley supports local (stdio) and Streamable HTTP servers, tools only, with fixed headers or a sign-in in your browser. Resources, prompts, sampling, elicitation and the old HTTP+SSE transport are not supported.",
                    "Tool calling: ReAct (text), in the wrench popover, is for models and servers without tool support. Tools go to the model as text in the system prompt, and the model answers with Action and Action Input lines. It is off by default, and Parley never switches to it on its own; the popover offers Use ReAct when a server refuses or ignores tools. Every ReAct call asks first and can only be allowed once, even for a tool you always allow, because text can repeat what a tool wrote. Tool servers' descriptions then sit in the system prompt, marked as data. ReAct relies on the model following a format, so some models will not use tools well this way. If a model's template opens its thinking, a call it only drafted while thinking can bring up a card, and that thinking then goes back to the model.",
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
                    "Parley only contacts the API endpoints and MCP servers you configure, and sign-in providers you approve. No telemetry, no analytics, no remote images. It looks for no servers on its own and reads no other app's MCP config.",
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
