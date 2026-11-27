import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public enum ComputerPermissions {
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    public static var accessibility: Bool { AXIsProcessTrusted() }
    public static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }
    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

public enum ComputerError: Error, CustomStringConvertible {
    case permission(String), noDisplay, encoding, badKey(String)
    public var description: String {
        switch self {
        case .permission(let m): return "permission needed: \(m)"
        case .noDisplay: return "no display found"
        case .encoding: return "could not encode the screenshot"
        case .badKey(let k): return "unknown key: \(k)"
        }
    }
}

/// Drives the real mouse and keyboard with CoreGraphics events and captures the screen with
/// ScreenCaptureKit. It needs the Screen Recording and Accessibility permissions, and it uses the
/// user's real cursor (there is no separate virtual cursor), so the user should not be using the
/// mouse while a task runs. This type cannot be exercised by automated tests; the agent loop that
/// drives it is tested against a scripted fake.
public final class MacComputerController: ComputerController, @unchecked Sendable {
    private let lock = NSLock()
    private var pointsPerPixel: CGFloat = 1
    private var origin: CGPoint = .zero
    private let longEdge: CGFloat = 1568

    private let excludesOwnWindows: Bool

    /// `excludingOwnWindows`: leave this app's windows (the notch, its glow) out of screenshots, so
    /// that what is read is the user's content and not the assistant's own status text.
    public init(excludingOwnWindows: Bool = false) { self.excludesOwnWindows = excludingOwnWindows }

    public func screenshot() async throws -> Data {
        guard ComputerPermissions.screenRecording else { throw ComputerError.permission("Screen Recording") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ComputerError.noDisplay }
        let own = excludesOwnWindows ? content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier } : []
        let k = min(1, longEdge / CGFloat(max(display.width, display.height)))
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * k)
        config.height = Int(CGFloat(display.height) * k)
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: config)
        setGeometry(scale: 1 / k, origin: display.frame.origin)

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ComputerError.encoding }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ComputerError.encoding }
        return data as Data
    }

    private func setGeometry(scale: CGFloat, origin: CGPoint) {
        lock.lock(); pointsPerPixel = scale; self.origin = origin; lock.unlock()
    }

    private func point(_ x: Int, _ y: Int) -> CGPoint {
        lock.lock(); defer { lock.unlock() }
        return CGPoint(x: origin.x + CGFloat(x) * pointsPerPixel, y: origin.y + CGFloat(y) * pointsPerPixel)
    }

    public func click(x: Int, y: Int, double: Bool) async throws {
        guard ComputerPermissions.accessibility else { throw ComputerError.permission("Accessibility") }
        let p = point(x, y)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 60_000_000)
        for n in 1...(double ? 2 : 1) {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    public func type(_ text: String) async throws {
        guard ComputerPermissions.accessibility else { throw ComputerError.permission("Accessibility") }
        // Unicode strings are injected in short runs: this handles every script, including CJK.
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e?.post(tap: .cghidEventTap)
            }
            i += chunk.count
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    public func key(_ combo: String) async throws {
        guard ComputerPermissions.accessibility else { throw ComputerError.permission("Accessibility") }
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:
                guard let k = Self.keyCodes[part] else { throw ComputerError.badKey(part) }
                code = k
            }
        }
        guard let code else { throw ComputerError.badKey(combo) }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    public func scroll(dx: Int, dy: Int) async throws {
        guard ComputerPermissions.accessibility else { throw ComputerError.permission("Accessibility") }
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?.post(tap: .cghidEventTap)
    }

    public func openApp(_ name: String) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", name]  // argv, never a shell string: the name cannot inject commands
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw ComputerError.badKey("application not found: \(name)") }
    }

    public func openURL(_ url: URL) async throws { NSWorkspace.shared.open(url) }
    public func openFile(path: String) async throws { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
        "backspace": 51, "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126, "-": 27, "=": 24, "[": 33, "]": 30,
        ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
    ]
}
