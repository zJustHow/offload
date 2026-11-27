import Foundation

/// The tools that look at and operate the Mac, over a `ComputerController`.
public enum ComputerTools {
    /// `vision`: whether the model can look at images. When it cannot, a screenshot is described
    /// as text (`screen_text`) instead of attached.
    public static func make(computer: ComputerController, memory: MemoryService, vision: Bool) -> [Tool] {
        /// After any screen action, show the result (as an image when the model can see, else as text).
        @Sendable func acted(_ what: String) async throws -> ToolOutput {
            try await Task.sleep(nanoseconds: 400_000_000)
            let shot = try await computer.screenshot()
            return vision ? .ok(what + "; new screenshot attached", image: shot) : .ok(what)
        }

        return [
            FunctionTool(ToolSpec(
                name: "open_source", description: "open an original file listed in a search result",
                inputSchema: JSONSchema.object(["uri": JSONSchema.string("the file path shown in a search result")], required: ["uri"]), tier: .act,
                promptExample: #"{"uri": "..."}"#
            )) { args in
                guard let uri = args.string("uri"), try memory.isKnownSource(uri: uri) else {
                    return .error("that is not a known source; only items returned by search_memory can be opened")
                }
                guard uri.hasPrefix("/") else { return .error("this source (\(uri)) cannot be opened directly; use open_app") }
                try await computer.openFile(path: uri)
                return .ok("opened \(uri)", image: try await computer.screenshot())
            },
            FunctionTool(ToolSpec(
                name: "screenshot", description: "look at the screen (click coordinates are pixels in that image)", promptExample: "{}"
            )) { _ in
                let shot = try await computer.screenshot()
                return vision ? .ok("screenshot attached", image: shot) : .ok("this model cannot see images; use screen_text")
            },
            FunctionTool(ToolSpec(name: "screen_text", description: "read the text on screen", promptExample: "{}")) { _ in
                .ok(try OCR.recognize(imageData: try await computer.screenshot()))
            },
            FunctionTool(ToolSpec(
                name: "click", description: "click at a pixel position of the last screenshot",
                inputSchema: JSONSchema.object(["x": JSONSchema.integer(), "y": JSONSchema.integer(), "double": JSONSchema.boolean("double-click")], required: ["x", "y"]), tier: .act,
                promptExample: #"{"x": 0, "y": 0, "double": false}"#
            )) { args in
                guard let x = args.int("x"), let y = args.int("y") else { return .error("x and y are required") }
                try await computer.click(x: x, y: y, double: args.bool("double") ?? false)
                return try await acted("clicked (\(x), \(y))")
            },
            FunctionTool(ToolSpec(
                name: "type", description: "type text into the focused field",
                inputSchema: JSONSchema.object(["text": JSONSchema.string()], required: ["text"]), tier: .act, promptExample: #"{"text": "..."}"#
            )) { args in
                guard let t = args.string("text") else { return .error("text is required") }
                try await computer.type(t)
                return try await acted("typed \(t.count) characters")
            },
            FunctionTool(ToolSpec(
                name: "key", description: "press a key combination",
                inputSchema: JSONSchema.object(["combo": JSONSchema.string("for example cmd+l, return, escape")], required: ["combo"]), tier: .act,
                promptExample: #"{"combo": "cmd+l"}"#
            )) { args in
                guard let c = args.string("combo") else { return .error("combo is required") }
                try await computer.key(c)
                return try await acted("pressed \(c)")
            },
            FunctionTool(ToolSpec(
                name: "scroll", description: "scroll the window under the pointer",
                inputSchema: JSONSchema.object(["dx": JSONSchema.integer(), "dy": JSONSchema.integer("negative scrolls down")]), tier: .act,
                promptExample: #"{"dx": 0, "dy": -300}"#
            )) { args in
                try await computer.scroll(dx: args.int("dx") ?? 0, dy: args.int("dy") ?? 0)
                return try await acted("scrolled")
            },
            FunctionTool(ToolSpec(
                name: "open_app", description: "open or switch to an application",
                inputSchema: JSONSchema.object(["name": JSONSchema.string()], required: ["name"]), tier: .act, promptExample: #"{"name": "Safari"}"#
            )) { args in
                guard let n = args.string("name") else { return .error("name is required") }
                try await computer.openApp(n)
                return try await acted("opened \(n)")
            },
            FunctionTool(ToolSpec(
                name: "open_url", description: "open a web or mail link in the default app",
                inputSchema: JSONSchema.object(["url": JSONSchema.string("an http, https or mailto URL")], required: ["url"]), tier: .act, promptExample: #"{"url": "https://..."}"#
            )) { args in
                // Only web and mail links: no file:, javascript:, custom schemes that trigger apps.
                guard let s = args.string("url"), let url = URL(string: s), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
                    return .error("only http(s) and mailto URLs may be opened")
                }
                try await computer.openURL(url)
                return try await acted("opened \(s)")
            },
        ]
    }
}
