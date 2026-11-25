import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }

    /// A short stable identifier derived from the given parts (collision odds are negligible at
    /// personal-data scale, and it keeps ids readable in logs).
    public static func stableID(_ parts: String...) -> String {
        String(sha256Hex(parts.joined(separator: "\u{1F}")).prefix(24))
    }
}

public enum Clock {
    /// Seconds since 1970, the unit used throughout the database.
    public static func epoch(_ date: Date) -> Double { date.timeIntervalSince1970 }
    public static func date(_ epoch: Double) -> Date { Date(timeIntervalSince1970: epoch) }
}
