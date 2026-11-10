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
                        Text("Parley Help")
                            .lettered(32)
                            .foregroundStyle(Hideout.emberText)
                            .accessibilityAddTraits(.isHeader)
                        Text("A private chat client for OpenAI-compatible APIs.")
                            .foregroundStyle(Hideout.inkSoft)
                    }
                }

                section("Getting started", "server.rack", [
                    "Open Settings (⌘,) > Providers and add a server. The base URL includes the version path, for example http://localhost:1234/v1 for LM Studio or https://api.openai.com/v1.",
                    "API keys are stored in your login Keychain and never synced. Local servers usually need no key.",
                    "Use Test Connection to load the server's model list. A new chat uses the provider's default model, or the first model the server lists. Change it with the model menu at the top of the window, which also accepts a custom model ID.",
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

                section("Built-in tools", "hammer", [
                    "Settings > Built-in Tools has six tools of Parley's own, all off until you turn them on. A tool that is on is offered in every conversation, with no MCP server needed. To leave them out of one conversation, untick Built-in tools in the wrench popover (⇧⌘T). With every tool off, Parley reads no file and contacts nothing new.",
                    "Current Time and Calculator run without asking, because they read nothing of yours and contact nothing. List Files, Read File, Fetch Web Page and Browse Web Page ask every time and can only be allowed once. In ReAct mode every call asks.",
                    "List Files and Read File work inside the one folder you choose in Settings, and only after you choose it. They read, never write. Hidden files are never listed or read, and the model is never told where the folder is. A link inside the folder that leads out of it is refused. A hard link cannot be told from an ordinary file, so one to a file outside the folder can be read. In a folder synced to iCloud or another cloud service, reading a file that is not on this Mac yet downloads it.",
                    "Fetch Web Page contacts the website directly from this Mac, so the site sees your IP address. It runs no scripts, loads no images, and sends no cookies, API keys or MCP headers. Private and local addresses are refused, and a redirect to another address is reported to the model instead of followed, so a new address means a new card.",
                    "Browse Web Page is for pages that only show their text once their scripts run. Each call opens the page in a new private browser that keeps nothing afterwards: no cookies, cache or storage come in or stay. Everything the page loads goes through a gate that lets only public addresses through, and images, video, fonts, popups and downloads are blocked. By default the page may load only from the address you approved, so some pages show little; the result tells the model how many requests to other sites were blocked. With \u{201C}Let Browse Web Page load from other sites\u{201D} on, the page's scripts may contact other websites, such as CDNs, and those sites see your IP address too. The card says which way it is. If the page moves to another address, Parley stops and a new card is needed. Stop, Lock and Quit close the page at once. It does not use the Mac's proxy settings, so behind a system proxy the site sees this Mac's own IP address.",
                    "The address check and the connection are separate lookups, so a site that changes its DNS answer in between, or a proxy, can make the request reach a device on your network before Parley sees that and throws the answer away. The model never receives that answer. A proxy that answers every name with its own address, as Clash and Surge can, means the check cannot tell a device on your network from a public site. The card is the real defence: read the address before you allow it.",
                    "What a tool returns goes to the model's provider, like any tool result. A page or a file can tell the model to read something and put it in an address. That is why these tools have no Always Allow: check the arguments on each card, the address above all.",
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
                    "Parley only contacts the API endpoints and MCP servers you configure, sign-in providers you approve and, if you turn on Fetch Web Page or Browse Web Page, each website you approve for one call (and, only if you allow it, the other public sites a browsed page's scripts load from). No telemetry, no analytics, no remote images. It looks for no servers on its own and reads no other app's MCP config.",
                    "The Copy buttons keep text off Universal Clipboard. Text you select and copy with ⌘C uses the normal clipboard.",
                ])
            }
            .padding(.horizontal, 34)
            .padding(.top, 36)
            .padding(.bottom, 34)
            // A little handbook taped up in the room, about 75 characters to the line.
            .frame(maxWidth: 660, alignment: .leading)
            .paperCard(Hideout.card, seed: 12, radius: 16)
            .overlay(alignment: .top) {
                WashiTape(color: Hideout.marigold, width: 104, height: 26, angle: -2)
                    .offset(y: -11)
            }
            .padding(.horizontal, 22)
            .padding(.top, 32)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 480, minHeight: 400)
    }

    private func section(_ title: String, _ symbol: String, _ paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title)
                    .lettered(21)
                    .foregroundStyle(Hideout.ink)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Hideout.emberText)
            }
            .accessibilityAddTraits(.isHeader)
            ForEach(paragraphs, id: \.self) { p in
                Text(p)
                    .fontDesign(.default)
                    .lineSpacing(3)
                    .foregroundStyle(Hideout.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
