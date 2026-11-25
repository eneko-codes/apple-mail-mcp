import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool hands `notices` to `Format`, which puts them before the data.
public final class Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    // MARK: Text

    /// Trimmed; text that is empty once trimmed counts as not given.
    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func requiredString(_ name: String) throws -> String {
        guard given(name) != nil else { throw ToolError.missingArgument(name) }
        guard let text = try optionalString(name) else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return text
    }

    public func bool(_ name: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    /// A list of text. One entry that is not text refuses the whole list: dropping it would
    /// send a message to fewer people than the caller named, with nothing to show for it.
    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = given(name) else { return [] }
        // A single string where an array is expected is a common and harmless slip.
        let entries = raw.stringValue.map { [Value.string($0)] } ?? raw.arrayValue
        guard let entries else {
            throw ToolError.badArgument(name: name, reason: "a list of text was expected")
        }
        return try entries.compactMap { entry -> String? in
            guard let text = entry.stringValue else {
                throw ToolError.badArgument(name: name, reason: "a list of text was expected")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: Numbers

    /// A quantity: a size, a count. Outside its range it is moved to the nearest allowed
    /// value, and `notices` gains the sentence that says which value was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = given(name) else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: Configuration.offsetRange)
        )
    }

    /// The `character_offset` and `max_characters` of a window on one long text.
    public func window() throws -> (characterOffset: Int, maxCharacters: Int) {
        (
            try int("character_offset", default: 0, in: Configuration.characterOffsetRange),
            try int(
                "max_characters", default: Configuration.defaultMaxCharacters,
                in: Configuration.maxCharactersRange)
        )
    }

    // MARK: Dates

    /// The three forms a date may take, as an error states them.
    static let dateForms = "2026-08-12, 2026-08-12T09:00 or 2026-08-12T09:00:00+02:00"

    /// `YYYY-MM-DD` and `YYYY-MM-DDTHH:MM[:SS]` are local time; the same followed by `Z` or
    /// an offset such as `+02:00` is that instant.
    ///
    /// `isDateOnly` records what the caller actually wrote, so that an upper bound given as
    /// a bare day can take in that whole day. A date that does not exist (30 February, an
    /// hour skipped by daylight saving) is refused: `Calendar` would otherwise roll it over
    /// to another day and the search would silently cover a range nobody asked for.
    public func optionalDate(_ name: String) throws -> (date: Date, isDateOnly: Bool)? {
        guard let raw = try optionalString(name) else { return nil }
        let refused = ToolError.badDate(argument: name, value: raw)

        let pieces = raw.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        let day = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
        guard day.count == 3, day[0].count == 4, day[1].count == 2, day[2].count == 2,
            let year = Self.digits(day[0]), let month = Self.digits(day[1]),
            let dayOfMonth = Self.digits(day[2])
        else { throw refused }
        var components = DateComponents(year: year, month: month, day: dayOfMonth)

        var isDateOnly = true
        var zone = calendar.timeZone
        if pieces.count == 2 {
            isDateOnly = false
            var time = pieces[1]
            if let offset = Self.zoneOffset(&time) {
                guard let fixed = TimeZone(secondsFromGMT: offset) else { throw refused }
                zone = fixed
            }
            let clock = time.split(separator: ":", omittingEmptySubsequences: false)
            guard (2...3).contains(clock.count), clock.allSatisfy({ $0.count == 2 }),
                let hour = Self.digits(clock[0]), let minute = Self.digits(clock[1])
            else { throw refused }
            components.hour = hour
            components.minute = minute
            if clock.count == 3 {
                guard let second = Self.digits(clock[2]) else { throw refused }
                components.second = second
            }
        }

        var local = calendar
        local.timeZone = zone
        guard let date = local.date(from: components) else { throw refused }
        // Reading the date back is what catches one that does not exist: the calendar
        // answers 30 February with 2 March instead of failing.
        let back = local.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == year, back.month == month, back.day == dayOfMonth,
            back.hour == (components.hour ?? 0), back.minute == (components.minute ?? 0),
            back.second == (components.second ?? 0)
        else { throw refused }
        return (date, isDateOnly)
    }

    /// Digits only: `Int("+5")` and `Int("-1")` succeed, and neither is part of a date.
    private static func digits(_ text: Substring) -> Int? {
        text.allSatisfy { $0.isASCII && $0.isNumber } ? Int(text) : nil
    }

    /// Removes a trailing `Z` or `±HH:MM` from `time` and returns it in seconds east of
    /// Greenwich; `nil`, with `time` untouched, when it carries neither.
    private static func zoneOffset(_ time: inout Substring) -> Int? {
        if time.hasSuffix("Z") {
            time = time.dropLast()
            return 0
        }
        guard let sign = time.lastIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        let parts = time[time.index(after: sign)...].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }),
            let hours = digits(parts[0]), let minutes = digits(parts[1]), hours <= 23, minutes <= 59
        else { return nil }
        let seconds = hours * 3600 + minutes * 60
        let offset = time[sign] == "-" ? -seconds : seconds
        time = time[..<sign]
        return offset
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

    /// An identifier is never moved to a neighbouring one: text that does not decode is
    /// refused.
    public func messageID(_ name: String) throws -> EmailID {
        let raw = try requiredString(name)
        guard let id = EmailID.decode(raw) else { throw ToolError.badIdentifier(raw) }
        return id
    }
}
