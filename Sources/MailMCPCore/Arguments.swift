import Foundation
import MCP

public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = values[name] else { return [] }
        if case .null = raw { return [] }
        // A single string where an array is expected is a common and harmless slip.
        if let single = raw.stringValue { return [single] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        return entries.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Dates

    /// `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM`, or full ISO 8601 with an offset.
    ///
    /// `isDateOnly` records what the caller actually wrote. Discarding it turned a bare
    /// day into midnight, so an upper bound documented as "on or before this date"
    /// excluded that whole day.
    public func optionalDate(_ name: String) throws -> (date: Date, isDateOnly: Bool)? {
        guard let raw = optionalString(name) else { return nil }

        let parts = raw.split(separator: "T", omittingEmptySubsequences: false)
        if parts.count == 1 || (parts.count == 2 && !raw.contains("Z") && !raw.contains("+")) {
            let dayParts = parts[0].split(separator: "-")
            guard dayParts.count == 3, let year = Int(dayParts[0]), let month = Int(dayParts[1]),
                let day = Int(dayParts[2]), (1...12).contains(month), (1...31).contains(day)
            else { throw ToolError.badDate(argument: name, value: raw) }

            var components = DateComponents(year: year, month: month, day: day)
            if parts.count == 2 {
                let time = parts[1].split(separator: ":")
                guard time.count >= 2, let hour = Int(time[0]), let minute = Int(time[1]),
                    (0...23).contains(hour), (0...59).contains(minute)
                else { throw ToolError.badDate(argument: name, value: raw) }
                components.hour = hour
                components.minute = minute
            }
            guard let date = calendar.date(from: components) else {
                throw ToolError.badDate(argument: name, value: raw)
            }
            return (date, parts.count == 1)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else {
            throw ToolError.badDate(argument: name, value: raw)
        }
        return (date, false)
    }

    // MARK: Addresses

    /// Deliberately minimal: something, an @, something, and a dot in the domain.
    ///
    /// Full RFC 5322 validation would reject addresses that work and accept ones that
    /// do not. This only catches the class of mistake worth catching before an
    /// irreversible send — a name where an address was meant.
    public static func isPlausibleAddress(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Accept "Name <a@b.com>" by looking only at the bracketed part.
        let candidate: String
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"),
            open < close
        {
            candidate = String(trimmed[trimmed.index(after: open)..<close])
        } else {
            candidate = trimmed
        }
        let halves = candidate.split(separator: "@", omittingEmptySubsequences: false)
        guard halves.count == 2, !halves[0].isEmpty, halves[1].contains("."),
            !halves[1].hasPrefix("."), !halves[1].hasSuffix("."),
            !candidate.contains(" ")
        else { return false }
        return true
    }

    public func addresses(_ name: String, required: Bool) throws -> [String] {
        let list = try stringArray(name)
        if required && list.isEmpty { throw ToolError.noRecipients }
        for address in list where !Self.isPlausibleAddress(address) {
            throw ToolError.invalidAddress(address)
        }
        return list
    }

    // MARK: Identifiers

    public func messageID(_ name: String) throws -> EmailID {
        let raw = try requiredString(name)
        guard let id = EmailID.decode(raw) else { throw ToolError.badIdentifier(raw) }
        return id
    }
}
