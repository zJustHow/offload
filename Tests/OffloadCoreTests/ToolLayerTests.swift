import XCTest
@testable import OffloadCore

/// A tool that records what it was asked to do, so a test can prove a refused call never ran.
final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [JSONObject] = []
    func record(_ a: JSONObject) { lock.lock(); calls.append(a); lock.unlock() }
}

func probeTool(_ name: String, tier: AccessTier = .readOnly, approval: ApprovalPolicy = .byPolicy, origin: ToolOrigin = .builtin,
               untrusted: Bool = false, deferred: Bool = false, description: String = "a test tool", probe: Probe = Probe(),
               result: String = "ok", isError: Bool = false) -> (Tool, Probe) {
    (FunctionTool(ToolSpec(
        name: name, description: description,
        inputSchema: JSONSchema.object(["text": JSONSchema.string(), "n": JSONSchema.integer(minimum: 1, maximum: 10), "flag": JSONSchema.boolean()], required: ["text"]),
        tier: tier, approval: approval, deferred: deferred, untrusted: untrusted, origin: origin)) { args in
            probe.record(args)
            return ToolOutput(result, isError: isError)
        }, probe)
}

final class ToolLayerTests: XCTestCase {
    // MARK: JSON values and schemas

    func testJSONValueRoundTripsAndKeepsBooleansApartFromNumbers() throws {
        let text = #"{"a":[1,2.5,"x",true,null],"b":{"c":false},"n":3}"#
        let v = try XCTUnwrap(JSONValue(jsonText: text))
        XCTAssertEqual(v["n"], .int(3))
        XCTAssertEqual(v["a"]?.asArray?[1], .double(2.5))
        XCTAssertEqual(v["a"]?.asArray?[3], .bool(true), "true is a boolean, not 1")
        XCTAssertEqual(v["b"]?["c"], .bool(false))
        XCTAssertEqual(JSONValue(jsonText: v.jsonText), v)
        XCTAssertEqual(JSONValue.string("10").asInt, 10, "models send numbers as strings")
        XCTAssertEqual(JSONValue.double(10.0).asInt, 10)
        XCTAssertNil(JSONValue.string("ten").asInt)
        XCTAssertEqual(JSONValue.string("true").asBool, true)
    }

    func testSchemaCoercionRepairsWhatIsUnambiguousAndValidationReportsTheRest() {
        let schema = JSONSchema.object(
            ["x": JSONSchema.integer(minimum: 0, maximum: 100), "ok": JSONSchema.boolean(), "paths": JSONSchema.array(of: JSONSchema.string()), "mode": JSONSchema.string(enum: ["a", "b"])],
            required: ["x"])
        let fixed = SchemaCheck.coerce(["x": "42", "ok": "true", "paths": "[\"a\",\"b\"]"], to: schema)
        XCTAssertEqual(fixed["x"], .int(42))
        XCTAssertEqual(fixed["ok"], .bool(true))
        XCTAssertEqual(fixed["paths"], .array(["a", "b"]), "a JSON array sent as a string is parsed")
        XCTAssertEqual(SchemaCheck.coerce(["paths": "single.md"], to: schema)["paths"], .array(["single.md"]), "a lone string becomes a list of one")
        XCTAssertEqual(SchemaCheck.validate(fixed, against: schema), [])

        XCTAssertEqual(SchemaCheck.validate([:], against: schema), ["x is required"])
        XCTAssertEqual(SchemaCheck.validate(["x": 500], against: schema), ["x must be at most 100"])
        XCTAssertEqual(SchemaCheck.validate(["x": 1, "mode": "c"], against: schema), ["mode must be one of: a, b"])
        XCTAssertEqual(SchemaCheck.validate(["x": "abc"], against: schema), ["x must be a integer"])
        XCTAssertEqual(SchemaCheck.validate(["x": 1, "extra": "ignored"], against: schema), [], "unknown properties are tolerated")
    }

    // MARK: Permission policy

    func testPermissionModesAndTiers() {
        let (read, _) = probeTool("look", tier: .readOnly), (write, _) = probeTool("edit", tier: .write), (act, _) = probeTool("press", tier: .act)
        func decide(_ mode: PermissionMode, _ tool: Tool, policy: PermissionPolicy? = nil) -> PermissionDecision {
            (policy ?? PermissionPolicy(mode: mode)).decide(ToolCall(name: tool.spec.name), spec: tool.spec, tier: tool.spec.tier)
        }
        XCTAssertEqual(decide(.act, act), .allow)
        XCTAssertEqual(decide(.act, read), .allow)
        XCTAssertEqual(decide(.write, write), .allow)
        if case .ask = decide(.write, act) {} else { XCTFail("a write session is one step short of act: it asks") }
        if case .deny = decide(.readOnly, act) {} else { XCTFail("a read-only session refuses to act") }
        if case .ask = decide(.readOnly, write) {} else { XCTFail("read-only is one step short of write: it asks") }
        XCTAssertEqual(decide(.allow, act), .allow)
        if case .ask = decide(.prompt, read) {} else { XCTFail("prompt mode asks about everything, even a lookup") }
        // The bug claw-code's ladder had: `prompt` must never rank above a tier and let everything through.
        XCTAssertFalse(PermissionMode.prompt.covers(.readOnly))
        XCTAssertTrue(PermissionMode.allow.covers(.act))
    }

    func testRulesOutrankModesAndDenyWins() {
        let (act, _) = probeTool("open_url", tier: .act)
        let call = ToolCall(name: "open_url", arguments: ["text": "https://example.com/a"])
        func decide(_ p: PermissionPolicy, hook: PermissionOverride? = nil) -> PermissionDecision { p.decide(call, spec: act.spec, tier: .act, hookOverride: hook) }

        XCTAssertEqual(decide(PermissionPolicy(mode: .act)), .allow)
        if case .deny = decide(PermissionPolicy(mode: .act, deny: [PermissionRule("open_url(https://example.com/*)")])) {} else { XCTFail("deny rule with an argument pattern") }
        XCTAssertEqual(decide(PermissionPolicy(mode: .act, deny: [PermissionRule("open_url(https://other.org/*)")])), .allow, "a pattern for another site does not match")
        XCTAssertEqual(decide(PermissionPolicy(mode: .readOnly, allow: [PermissionRule("open_url")])), .allow, "an allow rule is an explicit grant")
        if case .deny = decide(PermissionPolicy(mode: .readOnly, allow: [PermissionRule("open_url")], deny: [PermissionRule("open_*")])) {} else { XCTFail("deny beats allow") }
        if case .ask = decide(PermissionPolicy(mode: .allow, ask: [PermissionRule("OPEN_URL")])) {} else { XCTFail("ask rules apply even in allow mode; names match case-insensitively") }
        if case .deny = decide(PermissionPolicy(mode: .allow, deniedTools: ["open-url"])) {} else { XCTFail("denied tool names ignore case and separators") }

        // A hook can take permission away but never grant it.
        if case .deny = decide(PermissionPolicy(mode: .act), hook: .deny) {} else { XCTFail("hook deny") }
        if case .ask = decide(PermissionPolicy(mode: .act), hook: .ask) {} else { XCTFail("hook ask") }
    }

    func testAReadOnlySessionRefusesAToolThatActsEvenIfItWouldAlwaysAsk() {
        let (t, _) = probeTool("mcp__x__do", tier: .act, approval: .always, origin: .mcp(server: "x"))
        let call = ToolCall(name: t.spec.name, arguments: ["text": "x"])
        if case .deny = PermissionPolicy.readOnly.decide(call, spec: t.spec, tier: .act) {} else { XCTFail("two tiers short: refused, not asked") }
        if case .ask = PermissionPolicy(mode: .write).decide(call, spec: t.spec, tier: .act) {} else { XCTFail("one tier short: asked") }
        XCTAssertEqual(PermissionPolicy(mode: .readOnly, allow: [PermissionRule("mcp__x__*")]).decide(call, spec: t.spec, tier: .act), .allow, "an explicit allow still grants it")
    }

    func testToolsThatAlwaysAskAreOnlyGrantedByAnExplicitAllowRule() {
        let (t, _) = probeTool("mcp__notes__add", tier: .act, approval: .always, origin: .mcp(server: "notes"))
        let call = ToolCall(name: t.spec.name, arguments: ["text": "x"])
        if case .ask = PermissionPolicy(mode: .allow).decide(call, spec: t.spec, tier: .act) {} else { XCTFail("even allow mode asks about an unvetted external tool") }
        XCTAssertEqual(PermissionPolicy(mode: .act, allow: [PermissionRule("mcp__notes__*")]).decide(call, spec: t.spec, tier: .act), .allow)
    }

    func testRuleGlobMatching() {
        XCTAssertTrue(PermissionRule("mcp__*").matches(ToolCall(name: "mcp__a__b")))
        XCTAssertTrue(PermissionRule("click").matches(ToolCall(name: "click")))
        XCTAssertFalse(PermissionRule("click").matches(ToolCall(name: "click2")))
        XCTAssertTrue(PermissionRule("type(*password*)").matches(ToolCall(name: "type", arguments: ["text": "my password is x"])))
        XCTAssertFalse(PermissionRule("type(*password*)").matches(ToolCall(name: "type", arguments: ["text": "hello"])))
        let decoded = try? JSONDecoder().decode(PermissionPolicy.self, from: Data(#"{"mode":"read-only","deny":["click"]}"#.utf8))
        XCTAssertEqual(decoded?.mode, .readOnly)
        XCTAssertEqual(decoded?.deny.first?.raw, "click")
        XCTAssertEqual(try? JSONDecoder().decode(PermissionPolicy.self, from: Data("{}".utf8)).mode, .act, "an old config without the key still decodes")
    }

    // MARK: Dispatcher

    func makeDispatcher(_ tools: [Tool], policy: PermissionPolicy = PermissionPolicy(mode: .act), hooks: [ToolHook] = [],
                        approve: Bool? = nil, events: Box<[String]>? = nil) -> ToolDispatcher {
        ToolDispatcher(
            registry: ToolRegistry(tools), policy: policy, hooks: hooks,
            approver: approve.map { answer in { @Sendable _ in answer } },
            observer: events.map { box in { @Sendable e in box.append("\(e.tool):\(e.result.rawValue):\(e.asked)") } })
    }

    func testUnknownAndInvalidCallsNeverReachATool() async {
        let (tool, probe) = probeTool("look")
        let d = makeDispatcher([tool])
        let unknown = await d.dispatch(ToolCall(name: "teleport"))
        XCTAssertEqual(unknown.outcome, .unknown)
        XCTAssertTrue(unknown.output.isError)
        let invalid = await d.dispatch(ToolCall(name: "look", arguments: ["n": 99]))
        XCTAssertEqual(invalid.outcome, .invalid)
        XCTAssertTrue(invalid.output.text.contains("text is required"), invalid.output.text)
        XCTAssertTrue(invalid.output.text.contains("n must be at most 10"))
        XCTAssertTrue(probe.calls.isEmpty)

        let fixed = await d.dispatch(ToolCall(name: "LOOK", arguments: ["text": "hi", "n": "3"]))
        XCTAssertEqual(fixed.outcome, .ran, "name case and numeric strings are repaired")
        XCTAssertEqual(probe.calls.first?["n"], .int(3))
    }

    func testDeniedAndDeclinedCallsDoNotRun() async {
        let (act, probe) = probeTool("press", tier: .act)
        let events = Box<[String]>([])

        let denied = await makeDispatcher([act], policy: PermissionPolicy(mode: .readOnly), events: events).dispatch(ToolCall(name: "press", arguments: ["text": "x"]))
        if case .denied = denied.outcome {} else { XCTFail("\(denied.outcome)") }
        XCTAssertTrue(denied.output.text.hasPrefix("denied:"))

        let declined = await makeDispatcher([act], policy: PermissionPolicy(mode: .prompt), approve: false, events: events).dispatch(ToolCall(name: "press", arguments: ["text": "x"]))
        XCTAssertEqual(declined.outcome, .declined)
        XCTAssertTrue(declined.asked)

        let noApprover = await makeDispatcher([act], policy: PermissionPolicy(mode: .prompt)).dispatch(ToolCall(name: "press", arguments: ["text": "x"]))
        XCTAssertEqual(noApprover.outcome, .declined, "with nobody to ask, a question is a no")
        XCTAssertTrue(probe.calls.isEmpty)

        let approved = await makeDispatcher([act], policy: PermissionPolicy(mode: .prompt), approve: true, events: events).dispatch(ToolCall(name: "press", arguments: ["text": "x"]))
        XCTAssertEqual(approved.outcome, .ran)
        XCTAssertEqual(probe.calls.count, 1)
        XCTAssertEqual(events.value, ["press:denied:false", "press:declined:true", "press:ran:true"])
    }

    func testBackstopOnlyAddsAQuestion() async {
        let (act, probe) = probeTool("press", tier: .act)
        let asked = Box<[String]>([])
        let d = ToolDispatcher(registry: ToolRegistry([act]), policy: PermissionPolicy(mode: .act), approver: { r in asked.append(r.reason); return true },
                               backstop: { call, _ in call.arguments.string("text") == "send" ? "looks irreversible" : nil })
        _ = await d.dispatch(ToolCall(name: "press", arguments: ["text": "look"]))
        _ = await d.dispatch(ToolCall(name: "press", arguments: ["text": "send"]))
        XCTAssertEqual(asked.value, ["looks irreversible"])
        XCTAssertEqual(probe.calls.count, 2)

        // An allow rule does not silence the backstop...
        let d2 = ToolDispatcher(registry: ToolRegistry([act]), policy: PermissionPolicy(mode: .act, allow: [PermissionRule("press")]), approver: { _ in false },
                                backstop: { _, _ in "looks irreversible" })
        let r = await d2.dispatch(ToolCall(name: "press", arguments: ["text": "x"]))
        XCTAssertEqual(r.outcome, .declined)
        // ...and the model's own irreversible flag is stripped from the arguments the tool sees.
        let (act2, probe2) = probeTool("press", tier: .act)
        let d3 = ToolDispatcher(registry: ToolRegistry([act2]), policy: PermissionPolicy(mode: .act), approver: { _ in true }, backstop: { call, _ in call.declaredIrreversible ? "flagged" : nil })
        let flagged = await d3.dispatch(ToolCall(name: "press", arguments: ["text": "x", "irreversible": true]))
        XCTAssertTrue(flagged.asked)
        XCTAssertNil(probe2.calls.first?["irreversible"])
    }

    func testPlanningLimitsToReadOnlyTools() async {
        let (read, readProbe) = probeTool("look"), (act, actProbe) = probeTool("press", tier: .act)
        let d = makeDispatcher([read, act])
        d.readOnlyOnly = true
        let a = await d.dispatch(ToolCall(name: "look", arguments: ["text": "x"]))
        let b = await d.dispatch(ToolCall(name: "press", arguments: ["text": "x"]))
        XCTAssertEqual(a.outcome, .ran)
        if case .denied(let why) = b.outcome { XCTAssertTrue(why.contains("planning")) } else { XCTFail() }
        d.readOnlyOnly = false
        let c = await d.dispatch(ToolCall(name: "press", arguments: ["text": "x"]))
        XCTAssertEqual(c.outcome, .ran)
        XCTAssertEqual(readProbe.calls.count, 1)
        XCTAssertEqual(actProbe.calls.count, 1)
    }

    struct RewriteHook: ToolHook {
        func preToolUse(_ call: ToolCall, spec: ToolSpec) async -> PreToolResult {
            PreToolResult(updatedArguments: call.arguments.merging(["text": "rewritten"]) { _, new in new }, messages: ["(hook rewrote the text)"])
        }
        func postToolUse(_ call: ToolCall, spec: ToolSpec, output: ToolOutput) async -> ToolOutput {
            var o = output; o.text += " [post]"; return o
        }
    }
    struct VetoHook: ToolHook {
        func preToolUse(_ call: ToolCall, spec: ToolSpec) async -> PreToolResult { PreToolResult(override: .deny, reason: "vetoed by test") }
    }

    func testHooksRewriteArgumentsAndOutputAndCanVeto() async {
        let (tool, probe) = probeTool("look", result: "result")
        let r = await makeDispatcher([tool], hooks: [RewriteHook()]).dispatch(ToolCall(name: "look", arguments: ["text": "original"]))
        XCTAssertEqual(probe.calls.first?["text"], "rewritten")
        XCTAssertEqual(r.output.text, "result\n(hook rewrote the text) [post]")

        let (tool2, probe2) = probeTool("look")
        let v = await makeDispatcher([tool2], hooks: [RewriteHook(), VetoHook()]).dispatch(ToolCall(name: "look", arguments: ["text": "x"]))
        if case .denied(let why) = v.outcome { XCTAssertEqual(why, "vetoed by test") } else { XCTFail("\(v.outcome)") }
        XCTAssertTrue(probe2.calls.isEmpty)
    }

    func testBuiltInHooksRedactMarkUntrustedAndScrubArguments() async {
        let (tool, probe) = probeTool("fetch", tier: .act, origin: .mcp(server: "web"), untrusted: true, result: "Card 4111 1111 1111 1111 on file")
        let hooks: [ToolHook] = [OutputRedactionHook(), UntrustedContentHook(), ArgumentRedactionHook(appliesTo: { if case .mcp = $0.origin { return true } else { return false } })]
        let r = await makeDispatcher([tool], hooks: hooks).dispatch(ToolCall(name: "fetch", arguments: ["text": "my card is 4111 1111 1111 1111"]))
        XCTAssertEqual(r.outcome, .ran)
        XCTAssertFalse(probe.calls[0]["text"]!.asString!.contains("4111"), "the server never saw the card number")
        XCTAssertTrue(r.output.text.contains("[REDACTED:card]"))
        XCTAssertFalse(r.output.text.contains("4111"))
        XCTAssertTrue(r.output.text.contains("external source"), "third-party output is labelled as data")
    }

    func testTheAuditEventCarriesSizesNeverContents() async {
        let (tool, _) = probeTool("look", result: "secret text")
        let seen = Box<[ToolEvent]>([])
        let d = ToolDispatcher(registry: ToolRegistry([tool]), policy: PermissionPolicy(mode: .act), observer: { e in seen.mutate { $0.append(e) } })
        _ = await d.dispatch(ToolCall(name: "look", arguments: ["text": "my private query"]))
        let e = seen.value[0]
        XCTAssertEqual(e.tool, "look")
        XCTAssertEqual(e.outputCharacters, "secret text".count)
        XCTAssertFalse("\(e)".contains("private"))
        XCTAssertFalse("\(e)".contains("secret"))
    }

    // MARK: Registry

    func testRegistryFindsToolsByLooseNamesAndCanBeRestricted() {
        let reg = ToolRegistry([probeTool("search_memory").0, probeTool("read_note").0, probeTool("click", tier: .act).0])
        XCTAssertEqual(reg.tool(named: "Search-Memory")?.spec.name, "search_memory")
        XCTAssertEqual(reg.tool(named: "searchmemory")?.spec.name, "search_memory")
        XCTAssertNil(reg.tool(named: "search"))
        XCTAssertEqual(reg.subset(allowing: ["search_memory", "read_note"]).specs.map(\.name), ["search_memory", "read_note"])
        XCTAssertEqual(reg.subset(denying: ["click"]).specs.map(\.name), ["search_memory", "read_note"])
        reg.unregister(where: { $0.name == "click" })
        XCTAssertEqual(reg.specs.count, 2)
    }

    func testManyMCPToolsAreDeferredUntilSearchedFor() {
        var tools: [Tool] = [probeTool("search_memory").0, probeTool("extra", deferred: true).0]
        for i in 0..<8 { tools.append(probeTool("mcp__cal__tool\(i)", origin: .mcp(server: "cal"), description: i == 3 ? "create a calendar event" : "does thing \(i)").0) }
        let reg = ToolRegistry(tools)
        let split = reg.partition(autoDeferMCPAbove: 6)
        XCTAssertEqual(split.visible.map(\.name), ["search_memory"])
        XCTAssertEqual(split.hidden.count, 9)

        let few = ToolRegistry(Array(tools.prefix(5))).partition(autoDeferMCPAbove: 6)
        XCTAssertEqual(few.visible.count, 4, "a handful of MCP tools are simply listed")
        XCTAssertEqual(few.hidden.map(\.name), ["extra"], "an explicitly deferred tool stays hidden")

        let found = ToolRegistry.search("calendar event", in: split.hidden)
        XCTAssertEqual(found.first?.name, "mcp__cal__tool3")
        XCTAssertEqual(ToolRegistry.search("select:mcp__cal__tool5,nonexistent", in: split.hidden).map(\.name), ["mcp__cal__tool5"])
        XCTAssertEqual(ToolRegistry.search("+calendar thing", in: split.hidden).map(\.name), ["mcp__cal__tool3"], "+word is mandatory")
        XCTAssertTrue(ToolRegistry.search("zebra", in: split.hidden).isEmpty)
        XCTAssertEqual(reg.partition(activated: ["mcp__cal__tool5"], autoDeferMCPAbove: 6).visible.map(\.name), ["search_memory", "mcp__cal__tool5"])
    }

    func testPromptLinesAreGeneratedFromTheSchema() {
        let spec = probeTool("look").0.spec
        XCTAssertEqual(spec.promptLine, #"- look {"text": "...", "flag": false, "n": 0}: a test tool"#)
        var ex = spec; ex.promptExample = #"{"text": "..."}"#
        XCTAssertEqual(ex.promptLine, #"- look {"text": "..."}: a test tool"#)
        let native = probeTool("press", tier: .act).0.spec.nativeDefinition()
        XCTAssertNotNil(native.inputSchema["properties"]?[ToolSpec.irreversibleFlag], "tools that act get the irreversible flag in native mode")
        XCTAssertNil(probeTool("look").0.spec.nativeDefinition().inputSchema["properties"]?[ToolSpec.irreversibleFlag])
    }
}
