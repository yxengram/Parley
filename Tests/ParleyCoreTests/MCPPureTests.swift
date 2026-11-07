import Foundation
import Testing
@testable import ParleyCore

// Everything in the MCP layer that needs no server.

private func server(_ name: String, id: String = "00000000-0000-0000-0000-000000000001") -> MCPServerConfig {
    MCPServerConfig(id: UUID(uuidString: id)!, name: name)
}

private func tool(_ name: String) -> MCPTool {
    MCPTool(name: name, inputSchema: MCPSchema.normalized(nil))
}

private let safeName = try! NSRegularExpression(pattern: "^[a-z0-9_-]{1,64}$")

private func isSafe(_ name: String) -> Bool {
    safeName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
}

@Suite struct JSONValueTests {
    @Test func tellsBooleansFromNumbers() throws {
        let value = try #require(JSONValue(jsonText: #"{"t":true,"f":false,"one":1,"zero":0,"half":1.5,"null":null,"list":[1,"a"]}"#))
        #expect(value["t"] == .bool(true))
        #expect(value["f"] == .bool(false))
        #expect(value["one"] == .int(1))
        #expect(value["zero"] == .int(0))
        #expect(value["half"] == .double(1.5))
        #expect(value["null"] == .null)
        #expect(value["list"] == .array([.int(1), .string("a")]))
        #expect(value["missing"] == nil)
    }

    @Test func roundTripsThroughTheJSONWriter() throws {
        let text = #"{"a":[true,1,1.5,"x",null],"b":{"c":false}}"#
        #expect(JSONValue(jsonText: text)?.sortedJSONText == text)
    }

    @Test func codable() throws {
        let value = try #require(JSONValue(jsonText: #"{"a":[true,1,1.5,"x",null]}"#))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test func sortedTextIsStable() {
        let value: JSONValue = .object(["b": .int(1), "a": .object(["z": .null, "y": .bool(true)])])
        #expect(value.sortedJSONText == #"{"a":{"y":true,"z":null},"b":1}"#)
    }
}

@Suite struct MCPNamingTests {
    @Test func namesAreSafeForEveryKindOfName() {
        let long = "very_long_tool_name_" + String(repeating: "x", count: 108)
        let names = ["echo", "dotted.name", "dotted_name", "camelCaseTool", long, "日本語", "...", "A-B", "HTTPServer2Get"]
        let bindings = MCPToolNamer.assign([(server("My Server!"), names.map(tool))])
        #expect(bindings.count == names.count)
        #expect(Set(bindings.map(\.exposedName)).count == names.count)
        for binding in bindings {
            #expect(isSafe(binding.exposedName), "\(binding.exposedName)")
            #expect(binding.exposedName.hasPrefix("my_server__"))
        }
        #expect(bindings.first { $0.tool.name == "camelCaseTool" }?.exposedName == "my_server__camel_case_tool")
    }

    @Test func deterministicAcrossShuffledInput() {
        let a = server("Alpha", id: "00000000-0000-0000-0000-00000000000A")
        let b = server("Alpha", id: "00000000-0000-0000-0000-00000000000B")
        let tools = ["x", "y", "a.b", "a_b"].map(tool)
        let first = MCPToolNamer.assign([(a, tools), (b, tools.reversed())])
        for _ in 0..<5 {
            #expect(MCPToolNamer.assign([(b, tools.shuffled()), (a, tools.shuffled())]) == first)
        }
    }

    @Test func collidingToolNamesKeepTheirOwnNames() {
        let bindings = MCPToolNamer.assign([(server("s"), [tool("a.b"), tool("a_b")])])
        let names = bindings.map(\.exposedName)
        #expect(Set(names).count == 2)
        #expect(names.contains("s__a_b"))
        #expect(names.contains { $0.hasPrefix("s__a_b_") && $0.count == "s__a_b_".count + 6 })
    }

    @Test func twoServersWithOneName() {
        let a = server("Files", id: "AAAA0000-0000-0000-0000-000000000001")
        let b = server("Files", id: "BBBB0000-0000-0000-0000-000000000002")
        let names = MCPToolNamer.assign([(a, [tool("read")]), (b, [tool("read")])]).map(\.exposedName).sorted()
        #expect(names == ["files__read", "files_bbbb__read"])
    }

    @Test func aNamelessServerGetsAPrefix() {
        #expect(MCPToolNamer.assign([(server("日本語"), [tool("x")])]).first?.exposedName == "mcp__x")
    }

    @Test func enablingASecondServerRenamesNothing() throws {
        let a = server("Alpha", id: "00000000-0000-0000-0000-00000000000A")
        let z = server("Zeta", id: "00000000-0000-0000-0000-00000000000B")
        let alone = try #require(MCPToolNamer.assign([(a, [tool("x")])]).first?.exposedName)
        let both = MCPToolNamer.assign([(a, [tool("x")]), (z, [tool("y")])]).map(\.exposedName)
        #expect(both.contains(alone))
    }

    @Test func lookupExactThenNormalized() {
        let bindings = MCPToolNamer.assign([(server("files"), [tool("read_file"), tool("write")])])
        let catalog = MCPToolCatalog(bindings: bindings)
        #expect(catalog.binding(forFunctionName: "files__read_file")?.tool.name == "read_file")
        #expect(catalog.binding(forFunctionName: "FilesReadFile")?.tool.name == "read_file")
        #expect(catalog.binding(forFunctionName: "nope") == nil)
    }

    @Test func ambiguousLookupIsNil() {
        let a = MCPToolBinding(exposedName: "a_b", serverID: UUID(), serverName: "s", tool: tool("x"))
        let b = MCPToolBinding(exposedName: "a-b", serverID: UUID(), serverName: "s", tool: tool("y"))
        let catalog = MCPToolCatalog(bindings: [a, b])
        #expect(catalog.binding(forFunctionName: "AB") == nil)
        #expect(catalog.binding(forFunctionName: "a_b")?.tool.name == "x")
    }

    @Test func catalogIsSortedAndCounted() {
        let catalog = MCPToolCatalog(bindings: MCPToolNamer.assign([(server("s"), [tool("z"), tool("a")])]))
        #expect(catalog.chatTools.map(\.name) == ["s__a", "s__z"])
        #expect(catalog.definitionTokens > 0)
        #expect(MCPToolCatalog().definitionTokens == 0)
    }
}

@Suite struct MCPSchemaTests {
    private let empty: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    @Test func missingOrUselessBecomesAnEmptyObject() {
        #expect(MCPSchema.normalized(nil) == empty)
        #expect(MCPSchema.normalized(.null) == empty)
        #expect(MCPSchema.normalized(.string("x")) == empty)
        #expect(MCPSchema.normalized(.object([:])) == empty)
    }

    @Test func rootTypeIsAnObject() throws {
        #expect(MCPSchema.normalized(JSONValue(jsonText: #"{"properties":{}}"#))["type"] == .string("object"))
        #expect(MCPSchema.normalized(JSONValue(jsonText: #"{"type":["object","null"]}"#))["type"] == .string("object"))
    }

    @Test func booleanSubschemas() throws {
        let schema = JSONValue(jsonText: #"""
        {"type":"object","properties":{"x":true,"y":false,"z":{"type":"array","items":true}},
         "$defs":{"d":true},"definitions":{"e":false},"anyOf":[true,false,{"type":"string"}],
         "additionalProperties":false}
        """#)
        let out = MCPSchema.normalized(schema)
        #expect(out["properties"]?["x"] == .object([:]))
        #expect(out["properties"]?["y"] == nil)
        #expect(out["properties"]?["z"]?["items"] == .object([:]))
        #expect(out["$defs"]?["d"] == .object([:]))
        #expect(out["definitions"]?["e"] == nil)
        #expect(out["anyOf"]?.arrayValue?.count == 2)
        #expect(out["additionalProperties"] == .bool(false))
    }

    @Test func everythingElsePassesThrough() throws {
        let text = ##"{"$defs":{"a":{"format":"uuid","pattern":"^x"}},"$ref":"#/$defs/a","oneOf":[{"type":"string"}],"properties":{},"type":"object"}"##
        #expect(MCPSchema.normalized(JSONValue(jsonText: text)).sortedJSONText == text)
    }

    @Test func aPropertyNamedLikeAKeywordIsNotAKeyword() {
        let schema = JSONValue(jsonText: #"{"type":"object","properties":{"properties":{"type":"string"},"items":{"type":"number"}}}"#)
        let out = MCPSchema.normalized(schema)
        #expect(out["properties"]?["properties"]?["type"] == .string("string"))
    }

    @Test func deepNestingStops() {
        var value: JSONValue = .bool(true)
        for _ in 0..<500 { value = .object(["type": .string("object"), "properties": .object(["x": value])]) }
        _ = MCPSchema.normalized(value)
    }
}

@Suite struct MCPHeaderMirrorTests {
    private func problem(_ text: String) -> String? {
        MCPHeaderMirror.annotations(in: JSONValue(jsonText: text)!).problem
    }

    @Test func validAnnotations() {
        let schema = JSONValue(jsonText: #"{"type":"object","properties":{"a":{"type":"string","x-mcp-header":"Region"},"n":{"type":"object","properties":{"b":{"type":"integer","x-mcp-header":"Limit"}}}}}"#)!
        let found = MCPHeaderMirror.annotations(in: schema)
        #expect(found.problem == nil)
        #expect(found.list.map(\.header).sorted() == ["Limit", "Region"])
        #expect(MCPHeaderMirror.headers(schema: schema, arguments: ["a": .string("eu"), "n": .object(["b": .int(5)])])
                == ["Mcp-Param-Region": "eu", "Mcp-Param-Limit": "5"])
        #expect(MCPHeaderMirror.headers(schema: schema, arguments: ["a": .null]) == [:])
    }

    @Test func invalidAnnotations() {
        #expect(problem(#"{"properties":{"a":{"type":"array","items":{"type":"string","x-mcp-header":"X"}}}}"#) != nil)
        #expect(problem(#"{"properties":{"a":{"anyOf":[{"type":"string","x-mcp-header":"X"}]}}}"#) != nil)
        #expect(problem(#"{"properties":{"a":{"type":"number","x-mcp-header":"X"}}}"#) != nil)
        #expect(problem(#"{"properties":{"a":{"type":"string","x-mcp-header":""}}}"#) != nil)
        #expect(problem(#"{"properties":{"a":{"type":"string","x-mcp-header":"has space"}}}"#) != nil)
        #expect(problem(#"{"properties":{"a":{"type":"string","x-mcp-header":"X"},"b":{"type":"string","x-mcp-header":"x"}}}"#) != nil)
    }

    @Test func dataIsNotAnAnnotation() {
        #expect(problem(#"{"properties":{"a":{"type":"object","default":{"x-mcp-header":"X"}},"x-mcp-header":{"type":"string"}}}"#) == nil)
    }

    @Test func valueEncoding() {
        #expect(MCPHeaderMirror.encoded("us-west1") == "us-west1")
        #expect(MCPHeaderMirror.encoded("Hello, 世界") == "=?base64?SGVsbG8sIOS4lueVjA==?=")
        #expect(MCPHeaderMirror.encoded(" padded ") == "=?base64?IHBhZGRlZCA=?=")
        #expect(MCPHeaderMirror.encoded("line1\nline2") == "=?base64?bGluZTEKbGluZTI=?=")
        #expect(MCPHeaderMirror.encoded("=?base64?literal?=") == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
    }
}

@Suite struct MCPFingerprintTests {
    private let schema: JSONValue = .object(["type": .string("object")])

    @Test func anyChangeToTheDefinitionChangesIt() {
        let base = MCPTool(name: "t", description: "d", inputSchema: schema)
        #expect(base.fingerprint.count == 16)
        #expect(base.fingerprint == MCPTool(name: "t", description: "d", inputSchema: schema).fingerprint)
        #expect(base.fingerprint != MCPTool(name: "t", description: "other", inputSchema: schema).fingerprint)
        #expect(base.fingerprint != MCPTool(name: "u", description: "d", inputSchema: schema).fingerprint)
        #expect(base.fingerprint != MCPTool(name: "t", description: "d", inputSchema: .object(["type": .string("string")])).fingerprint)
    }

    @Test func aTitleIsNotPartOfIt() {
        #expect(MCPTool(name: "t", title: "A", inputSchema: schema).fingerprint == MCPTool(name: "t", title: "B", inputSchema: schema).fingerprint)
    }

    @Test func serverFingerprints() {
        let config = MCPServerConfig(name: "s", command: "npx")
        let base = MCPServerSecrets(args: ["-y", "pkg"], env: ["A": "1"])
        let (connection, identity) = MCPServerConfig.fingerprints(config: config, secrets: base)
        #expect(MCPServerConfig.fingerprints(config: config, secrets: base).connection == connection)

        // An env value changes neither (AppState stops the server on any secret change).
        let otherValue = MCPServerConfig.fingerprints(config: config, secrets: MCPServerSecrets(args: ["-y", "pkg"], env: ["A": "2"]))
        #expect(otherValue.identity == identity)

        var moved = config
        moved.workingDirectory = "/tmp"
        #expect(MCPServerConfig.fingerprints(config: moved, secrets: base).connection != connection)
        #expect(MCPServerConfig.fingerprints(config: moved, secrets: base).identity != identity)

        let otherArgs = MCPServerSecrets(args: ["-y", "other"])
        #expect(MCPServerConfig.fingerprints(config: config, secrets: otherArgs).identity != identity)

        // The hash stands in for the secret, it does not contain it.
        #expect(!connection.contains("pkg") && connection.count == 64)
    }
}

@Suite struct MCPConfigCodingTests {
    @Test func aLaterKindDecodes() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"x","kind":"carrier-pigeon","extra":1}"#
        let config = try JSONDecoder().decode(MCPServerConfig.self, from: Data(json.utf8))
        #expect(config.kind == "carrier-pigeon")
        #expect(config.isEnabled == false)
    }

    @Test func roundTrip() throws {
        var config = MCPServerConfig(name: "x", command: "npx", envNames: ["A"], disabledTools: ["t"], alwaysAllowedTools: ["t": "abc"])
        config.callTimeout = 5
        #expect(try JSONDecoder().decode(MCPServerConfig.self, from: try JSONEncoder().encode(config)) == config)
    }

    @Test func defaults() {
        #expect(MCPServerConfig(name: "s").effectiveStartupTimeout == 120)
        #expect(MCPServerConfig(name: "h", kind: MCPServerConfig.kindHTTP).effectiveStartupTimeout == 20)
        #expect(MCPServerConfig(name: "s").effectiveCallTimeout == 120)
        #expect(MCPServerConfig(name: "s").effectiveMaxResultCharacters == 32_000)
    }

    @Test func secretStore() throws {
        let store = InMemoryMCPSecretStore()
        let id = UUID()
        #expect(try store.secrets(for: id) == MCPServerSecrets())
        try store.setSecrets(MCPServerSecrets(url: "https://x"), for: id)
        #expect(try store.secrets(for: id).url == "https://x")
        try store.setSecrets(MCPServerSecrets(), for: id)
        #expect(try store.secrets(for: id) == MCPServerSecrets())
        #expect(store.readCount == 3)
    }

    @Test func secretsDecodeWithFieldsMissing() throws {
        let secrets = try JSONDecoder().decode(MCPServerSecrets.self, from: Data(#"{"url":"https://x.test"}"#.utf8))
        #expect(secrets == MCPServerSecrets(url: "https://x.test"))
    }

    @Test func secretsWithLineBreaksInHeadersAreRefused() {
        #expect(MCPServerSecrets(headers: ["A": "ok"]).invalidHeaderName == nil)
        #expect(MCPServerSecrets(headers: ["A": "x\r\nEvil: 1"]).invalidHeaderName == "A")
        #expect(MCPServerSecrets(headers: ["B\n": "x"]).invalidHeaderName == "B\n")
    }
}

@Suite struct ToolResultProjectionTests {
    private func project(_ text: String, max: Int = 32_000) -> ToolCallResult {
        ToolResultProjection.project(result: JSONValue(jsonText: text)!, maxCharacters: max)
    }

    @Test func textJoins() {
        let r = project(#"{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}"#)
        #expect(r.text == "a\nb")
        #expect(r.status == ToolCallStatus.completed.rawValue)
        #expect(r.omitted == nil)
    }

    @Test func embeddedTextAndLinks() {
        let r = project(#"{"content":[{"type":"resource","resource":{"uri":"m://a","text":"inner"}},{"type":"resource_link","uri":"file:///x","name":"x"}]}"#)
        #expect(r.text == "inner\n[Link: x file:///x]")
    }

    @Test func imagesAudioAndBlobsAreLeftOutWithANote() {
        let data = Data(repeating: 0, count: 3 * 1024).base64EncodedString()
        let r = project(#"{"content":[{"type":"text","text":"see"},{"type":"image","mimeType":"image/png","data":"\#(data)"},{"type":"audio","mimeType":"audio/wav","data":"AAAA"},{"type":"resource","resource":{"uri":"m://b","mimeType":"application/pdf","blob":"AAAA"}}]}"#)
        #expect(r.omitted == ["image/png, 3 KB", "audio/wav, 3 bytes", "application/pdf, 3 bytes"])
        #expect(r.text.hasPrefix("see\n\n[Parley could not pass on: image/png, 3 KB; "))
        #expect(!r.text.contains(data))
    }

    @Test func unknownContentType() {
        let r = project(#"{"content":[{"type":"hologram"}]}"#)
        #expect(r.text.hasPrefix("[Unsupported content: hologram]"))
        #expect(r.omitted == ["hologram"])
    }

    @Test func structuredOnlyWhenThereIsNoText() {
        #expect(project(#"{"content":[],"structuredContent":{"b":1,"a":2}}"#).text == #"{"a":2,"b":1}"#)
        #expect(project(#"{"content":[{"type":"text","text":"t"}],"structuredContent":{"a":1}}"#).text == "t")
    }

    @Test func isErrorIsMarked() {
        let r = project(#"{"isError":true,"content":[{"type":"text","text":"bad"}]}"#)
        #expect(r.status == ToolCallStatus.toolError.rawValue)
        #expect(r.text == "The tool reported an error:\nbad")
    }

    @Test func truncationCountsCharacters() {
        let text = String(repeating: "世", count: 100)
        let r = project(#"{"content":[{"type":"text","text":"\#(text)"}]}"#, max: 10)
        #expect(r.originalCharacters == 100)
        #expect(r.text == String(repeating: "世", count: 10) + "\n\n[Truncated by Parley: showing the first 10 of 100 characters.]")
    }

    @Test func emptyResults() {
        #expect(project(#"{"content":[]}"#).text == ToolResultText.empty)
        #expect(project(#"{}"#).text == ToolResultText.empty)
    }
}

@Suite struct MCPWireTests {
    @Test func oneLineAlways() throws {
        let message = MCPOutbound(id: 7, method: "tools/call", params: .object(["text": .string("two\nlines")]))
        let data = MCPWire.encode(message)
        #expect(!data.contains(0x0A))
        #expect(JSONValue(jsonData: data)?["id"] == .int(7))
    }

    @Test func notificationHasNoID() {
        #expect(JSONValue(jsonData: MCPWire.encode(MCPOutbound(method: "x", params: nil)))?["id"] == nil)
    }

    @Test func decodesEveryKind() {
        #expect(MCPWire.decode(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) == [.response(id: .int(1), result: .object([:]), error: nil)])
        #expect(MCPWire.decode(Data(#"{"jsonrpc":"2.0","id":"x","method":"ping"}"#.utf8)) == [.request(id: .string("x"), method: "ping", params: nil)])
        #expect(MCPWire.decode(Data(#"{"jsonrpc":"2.0","method":"n"}"#.utf8)) == [.notification(method: "n", params: nil)])
        #expect(MCPWire.decode(Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-1,"message":"m"}}"#.utf8))
                == [.response(id: .null, result: nil, error: MCPRPCError(code: -1, message: "m"))])
    }

    @Test func decodesABatch() {
        #expect(MCPWire.decode(Data(#"[{"id":1,"result":{}},{"method":"n"}]"#.utf8))?.count == 2)
    }

    @Test func refusesWhatIsNotJSONRPC() {
        #expect(MCPWire.decode(Data("npm WARN".utf8)) == nil)
        #expect(MCPWire.decode(Data("[1]".utf8)) == nil)
        #expect(MCPWire.decode(Data(#"{"hello":1}"#.utf8)) == nil)
    }

    @Test func responseShapes() {
        let ok = JSONValue(jsonData: MCPWire.encodeResponse(id: .string("a"), result: nil, error: nil))
        #expect(ok?["result"] == .object([:]))
        let failed = JSONValue(jsonData: MCPWire.encodeResponse(id: .int(1), result: nil, error: MCPRPCError(code: -32601, message: "no")))
        #expect(failed?["error"]?["code"] == .int(-32601))
    }

    @Test func authorizationTextSaysSo() {
        #expect(MCPError.needsAuthorization(status: 401).errorDescription == "This server needs you to sign in. Press Sign In in Settings > MCP, or add a static Authorization header if the server accepts one.")
        #expect(MCPError.needsAuthorization(status: 403).errorDescription == "The server refused the request (HTTP 403). Check your access to this server and any headers set for it.")
    }
}

@Suite struct MCPLogBufferTests {
    @Test func linesInPieces() {
        let log = MCPLogBuffer()
        log.append(Data("one\ntw".utf8))
        log.append(Data("o\r\n".utf8))
        #expect(log.snapshot() == ["one", "two"])
    }

    @Test func staysBounded() {
        let log = MCPLogBuffer(maxLines: 10, maxBytes: 100, maxLineBytes: 8)
        for i in 0..<100 { log.append(line: "line \(i)") }
        #expect(log.snapshot().count <= 10)
        log.append(Data(repeating: 0x61, count: 500))
        #expect(log.snapshot().last?.count == 8)
        #expect(log.tail(1).count == 1)
        log.clear()
        #expect(log.snapshot().isEmpty)
    }

    @Test func lossyUTF8() {
        let log = MCPLogBuffer()
        log.append(Data([0xFF, 0x41, 0x0A]))
        #expect(log.snapshot().first?.contains("A") == true)
    }
}

@Suite struct MCPImportTests {
    private func one(_ text: String) throws -> MCPImportEntry {
        try #require(try MCPConfigImport.parse(text).first)
    }

    @Test func standardShape() throws {
        let entries = try MCPConfigImport.parse(#"""
        {"mcpServers":{
          "files":{"command":"npx","args":["-y","@scope/server","/tmp"],"env":{"TOKEN":"fake-token"}},
          "remote":{"url":"https://example.test/mcp/fake-path-token","headers":{"Authorization":"Bearer fake"}}
        }}
        """#)
        try #require(entries.map(\.config.name) == ["files", "remote"])
        let files = entries[0]
        #expect(files.config.kind == MCPServerConfig.kindStdio)
        #expect(files.config.command == "npx")
        #expect(files.config.envNames == ["TOKEN"])
        #expect(files.secrets.args == ["-y", "@scope/server", "/tmp"])
        #expect(files.secrets.env == ["TOKEN": "fake-token"])
        #expect(files.config.isEnabled)
        #expect(!files.config.useInNewChats)
        let remote = entries[1]
        #expect(remote.config.kind == MCPServerConfig.kindHTTP)
        #expect(remote.config.urlHost == "example.test")
        #expect(remote.config.headerNames == ["Authorization"])
        #expect(remote.secrets.url == "https://example.test/mcp/fake-path-token")
        #expect(remote.secrets.headers == ["Authorization": "Bearer fake"])
    }

    @Test func secretsStayOutOfTheConfig() throws {
        let entries = try MCPConfigImport.parse(#"""
        {"mcpServers":{"a":{"command":"mcp-remote","args":["--header","Authorization: Bearer fake-arg-token"],"env":{"K":"fake-env-token"}},
                       "b":{"url":"https://host.test/fake-url-token","headers":{"X":"fake-header-token"}}}}
        """#)
        let encoded = String(decoding: try JSONEncoder().encode(entries.map(\.config)), as: UTF8.self)
        for secret in ["fake-arg-token", "fake-env-token", "fake-url-token", "fake-header-token"] {
            #expect(!encoded.contains(secret))
        }
    }

    @Test func otherShapes() throws {
        #expect(try one(#"{"servers":{"v":{"type":"http","url":"https://x.test/a"}}}"#).config.name == "v")
        #expect(try one(#"{"inner":{"command":"uvx","args":["x"]}}"#).config.command == "uvx")
        #expect(try one(#""inner":{"command":"uvx"}"#).config.name == "inner")
        #expect(try one(#"{"command":"uvx"}"#).config.name == MCPConfigImport.singleServerName)
        #expect(try one(#"{"url":"https://x.test/a"}"#).config.kind == MCPServerConfig.kindHTTP)
        #expect(try one("""
        // a comment, as JSONC has
        {"mcpServers":{"a":{"command":"x",},},}
        """).config.command == "x")
    }

    @Test func refusals() throws {
        #expect(throws: MCPImportError.notJSON) { try MCPConfigImport.parse("not json at all [") }
        #expect(throws: MCPImportError.noServers) { try MCPConfigImport.parse(#"{"other":1}"#) }
        #expect(try one(#"{"mcpServers":{"old":{"type":"sse","url":"https://x.test/sse"}}}"#).error == "This server uses an older connection type (HTTP+SSE) that Parley does not support.")
        #expect(try one(#"{"mcpServers":{"bad":{"url":"ftp://x.test"}}}"#).error != nil)
        #expect(try one(#"{"mcpServers":{"bad":{"command":""}}}"#).error != nil)
        #expect(try one(#"{"mcpServers":{"bad":{"url":"https://x.test","headers":{"A":"b\r\nEvil: 1"}}}}"#).error != nil)
    }

    @Test func variablesAreKeptLiterally() throws {
        let entry = try one(#"{"a":{"command":"x","env":{"K":"${TOKEN}"}}}"#)
        #expect(entry.secrets.env["K"] == "${TOKEN}")
        #expect(entry.warnings.contains { $0.contains("does not expand") })
        #expect(try one(#"{"a":{"url":"https://x.test","headers":{"A":"Bearer ${input:t}"}}}"#).warnings.count == 1)
    }

    @Test func ignoredKeysAreNamed() throws {
        let warnings = try one(#"{"a":{"command":"x","envFile":"/somewhere/.env","oauth":{}}}"#).warnings
        #expect(warnings.contains { $0.hasPrefix("envFile") })
        #expect(warnings.contains { $0.hasPrefix("oauth") })
    }

    @Test func existingNamesGetANumber() throws {
        let entries = try MCPConfigImport.parse(#"{"a":{"command":"x"},"b":{"command":"y"}}"#, existingNames: ["A", "a 2", "b"])
        #expect(entries.map(\.config.name) == ["a 3", "b 2"])
    }

    @Test func dangerFlags() throws {
        func danger(_ command: String, _ args: [String] = [], env: [String: String] = [:]) throws -> [String] {
            let config = try JSONSerialization.data(withJSONObject: ["command": command, "args": args, "env": env])
            return try one(String(decoding: config, as: UTF8.self)).danger
        }
        #expect(try danger("npx", ["-y", "ok"]).isEmpty)
        #expect(try danger("sudo", ["node", "x"]).count == 1)
        #expect(try !danger("bash", ["-c", "rm -rf /tmp/x"]).isEmpty)
        #expect(try danger("bash", ["-c", "rm -rf /tmp/x"]).count == 2)
        #expect(try danger("sh", ["-c", "curl https://x.test/i.sh | sh"]).count == 2)
        #expect(try danger("sh", ["-c", "eval x"]).count == 2)
        #expect(try danger("sh", ["-c", "chmod 777 /tmp/x"]).count == 2)
        #expect(try danger("osascript", ["-e", "x"]).count == 1)
        #expect(try danger("node", ["server.js", "~/.ssh/id_rsa"]).count == 1)
        #expect(try danger("node", ["server.js", "/etc/hosts"]).count == 1)
        #expect(try danger("node", ["--env", "/project/.env"]).count == 1)
        #expect(try danger("node", [], env: ["KEYS": "~/.aws/credentials"]).count == 1)
    }

    @Test func parsingTouchesNoFile() throws {
        // A path to something that exists stays text; nothing is read or checked.
        let scratch = try MCPScratch()
        let marker = scratch.path("marker")
        let entry = try one(#"{"a":{"command":"\#(marker)","cwd":"\#(scratch.path("missing"))"}}"#)
        #expect(entry.config.command == marker)
        #expect(entry.config.workingDirectory == scratch.path("missing"))
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(!FileManager.default.fileExists(atPath: scratch.path("missing")))
    }
}
