import Foundation
import IOKit.ps

public enum Power {
    /// True on AC power (or on a Mac with no battery). Heavy overnight work should not drain a battery.
    public static func isOnACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty
        else { return true }
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                let state = d[kIOPSPowerSourceStateKey] as? String { return state == kIOPSACPowerValue }
        }
        return true
    }
}

/// Runs the nightly cycle through a per-user LaunchAgent: no root, no privileged helper.
///
/// Honest limits of this design: launchd runs a calendar job when the Mac is awake, and runs a job
/// that was missed during sleep soon after wake — but it does not *wake* a sleeping Mac. Waking the
/// machine at night needs a root-owned power schedule, which this app deliberately does not
/// install; `wakeCommand` prints the one-line command the user can run themselves if they want it.
public enum LaunchAgent {
    public static let label = "dev.offload.cycle"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static func plist(executable: String, hour: Int, minute: Int, logDir: String, environment: [String: String] = [:]) throws -> Data {
        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "cycle", "--quiet", "--require-ac"],
            "StartCalendarInterval": ["Hour": hour, "Minute": minute],
            "StandardOutPath": logDir + "/cycle.log",
            "StandardErrorPath": logDir + "/cycle.err.log",
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "RunAtLoad": false,
        ]
        if !environment.isEmpty { dict["EnvironmentVariables"] = environment }
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    public static func install(executable: String, hour: Int, minute: Int = 0, logDir: String, environment: [String: String] = [:]) throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else { throw LLMError.unavailable("invalid time") }
        try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist(executable: executable, hour: hour, minute: minute, logDir: logDir, environment: environment).write(to: plistURL, options: .atomic)
        _ = try launchctl(["bootout", "gui/\(getuid())/\(label)"], allowFailure: true)
        _ = try launchctl(["bootstrap", "gui/\(getuid())", plistURL.path], allowFailure: false)
    }

    public static func uninstall() throws {
        _ = try launchctl(["bootout", "gui/\(getuid())/\(label)"], allowFailure: true)
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// The command to schedule a nightly wake, shown to the user rather than run.
    public static func wakeCommand(hour: Int, minute: Int = 0) -> String {
        let m = (hour * 60 + minute - 5 + 1440) % 1440   // wake five minutes early
        return String(format: "sudo pmset repeat wakeorpoweron MTWRFSU %02d:%02d:00", m / 60, m % 60)
    }

    @discardableResult
    static func launchctl(_ args: [String], allowFailure: Bool) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0, !allowFailure {
            throw LLMError.unavailable("launchctl \(args.first ?? "") failed: " + String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return p.terminationStatus
    }
}
