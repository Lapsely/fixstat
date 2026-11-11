import Foundation
import MacSensors

/// How often macOS had to hold the Mac back for heat, from the system log (no root): thermalmonitord
/// logs every change of the thermal pressure level as "mTPL = N" (0 nominal, 1 moderate, 2 heavy,
/// 3 trapping, 4 sleeping), and `pmset -g log` names sleeps forced by heat ("Thermal Emergency").
/// Overheating a customer cannot see: a blocked fan, dried paste, a Mac closed in a bag (this M1 Air
/// reached level 4 in a dark wake and was put to sleep).
public struct ThermalHistory: Equatable, Sendable {
    public struct Episode: Equatable, Sendable {
        public let start: Date
        public let end: Date
        /// Highest level reached (1 … 4).
        public let peak: Int
        public var seconds: TimeInterval { end.timeIntervalSince(start) }
    }

    /// Periods above nominal, oldest first.
    public let episodes: [Episode]
    /// Seconds spent at each level 1 … 4 (index 0 = level 1).
    public let secondsAtLevel: [TimeInterval]
    /// Sleeps macOS forced because of heat.
    public let emergencySleeps: [Date]
    /// thermalmonitord runs on this Mac, so an empty log means "no pressure", not "no data".
    public let sourceAvailable: Bool
    public let days: Int

    /// Seconds at heavy pressure or worse (the CPU / GPU clearly slowed).
    public var heavySeconds: TimeInterval { secondsAtLevel.dropFirst().reduce(0, +) }
    public var heavyEpisodes: [Episode] { episodes.filter { $0.peak >= 2 } }

    /// Worth a technician's look: heavy pressure for a minute or more, or a forced sleep.
    public var needsAttention: Bool { heavySeconds >= 60 || !emergencySleeps.isEmpty || episodes.contains { $0.peak >= 4 } }

    public static let defaultDays = 7

    /// Reads the log (a few seconds: run it in the background).
    public static func read(days: Int = defaultDays) -> ThermalHistory {
        let log = Command.output("/usr/bin/log", ["show", "--last", "\(days)d", "--style", "compact", "--predicate",
                                                  #"process == "thermalmonitord" AND eventMessage BEGINSWITH "mTPL""#]) ?? ""
        let pmset = Command.output("/usr/bin/pmset", ["-g", "log"]) ?? ""
        let running = !(Command.output("/usr/bin/pgrep", ["-x", "thermalmonitord"]) ?? "").isEmpty
        return parse(log: log, pmsetLog: pmset, sourceAvailable: running, days: days, now: Date())
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// `log`: compact lines "2026-11-10 19:18:24.312 Df thermalmonitord[139:7aa] mTPL = 1";
    /// `pmsetLog`: lines with "Thermal Emergency".
    public static func parse(log: String, pmsetLog: String, sourceAvailable: Bool, days: Int, now: Date) -> ThermalHistory {
        var changes: [(Date, Int)] = []
        for line in log.split(separator: "\n") {
            guard line.count > 23, let range = line.range(of: "mTPL = "),
                  let level = Int(line[range.upperBound...].prefix { $0.isNumber }),
                  let date = formatter.date(from: String(line.prefix(19))) else { continue }
            changes.append((date, min(max(level, 0), 4)))
        }
        changes.sort { $0.0 < $1.0 }

        // A level holds until the next change, but not through a sleep: the Mac that slept at level 4
        // logs its next level only after waking.
        let sleeps = pmsetLog.split(separator: "\n").compactMap { line -> Date? in
            guard line.contains("Entering Sleep") else { return nil }
            return formatter.date(from: String(line.prefix(19)))
        }.sorted()
        // pmset logs whole seconds and can write the forced sleep a moment before the level that caused it.
        func until(_ date: Date, _ next: Date) -> Date {
            sleeps.first { $0 > date.addingTimeInterval(-5) && $0 < next }.map { max(date, $0) } ?? next
        }

        var episodes: [Episode] = []
        var seconds = [TimeInterval](repeating: 0, count: 4)
        var start: Date?
        var activeEnd: Date?
        var peak = 0
        for (index, (date, level)) in changes.enumerated() {
            // The last change holds until now, at most an hour.
            let next = until(date, index + 1 < changes.count ? changes[index + 1].0 : min(now, date.addingTimeInterval(3600)))
            if level >= 1 {
                seconds[level - 1] += max(0, next.timeIntervalSince(date))
                if start == nil { start = date; peak = 0 }
                peak = max(peak, level)
                activeEnd = next
            } else if let s = start {
                episodes.append(Episode(start: s, end: activeEnd ?? date, peak: peak))
                start = nil
            }
        }
        if let s = start, let end = activeEnd {
            episodes.append(Episode(start: s, end: end, peak: peak))
        }
        // Episodes a minute apart are one (the level steps down and up again).
        var merged: [Episode] = []
        for episode in episodes {
            if let previous = merged.last, episode.start.timeIntervalSince(previous.end) < 60 {
                merged[merged.count - 1] = Episode(start: previous.start, end: episode.end, peak: max(previous.peak, episode.peak))
            } else {
                merged.append(episode)
            }
        }

        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let emergencies = pmsetLog.split(separator: "\n").compactMap { line -> Date? in
            guard line.contains("Thermal Emergency"), let date = formatter.date(from: String(line.prefix(19))),
                  date >= cutoff else { return nil }
            return date
        }
        return ThermalHistory(episodes: merged, secondsAtLevel: seconds, emergencySleeps: emergencies,
                              sourceAvailable: sourceAvailable || !changes.isEmpty, days: days)
    }
}

/// Texts of the overheating history (device card, PDF).
public enum ThermalHistoryText {
    public static func level(_ level: Int) -> String {
        switch level {
        case 1: return L("moderate")
        case 2: return L("heavy")
        case 3: return L("trapping (strongly slowed)")
        default: return L("sleep (emergency)")
        }
    }

    /// "none" / "3 times, 12 min heavy or worse · 1 forced sleep"
    public static func summary(_ h: ThermalHistory) -> String {
        guard h.sourceAvailable else { return L("not recorded on this Mac") }
        if h.episodes.isEmpty, h.emergencySleeps.isEmpty { return L("none in the last %lld days", h.days) }
        var parts: [String] = []
        if !h.episodes.isEmpty {
            parts.append(L("%1$lld times, %2$@ heavy or worse", h.episodes.count, Format.duration(h.heavySeconds)))
        }
        if !h.emergencySleeps.isEmpty { parts.append(L("%lld sleeps forced by heat", h.emergencySleeps.count)) }
        return parts.joined(separator: " · ")
    }

    /// Latest episodes first: "10 Nov 19:18 · 25 s · peak: sleep (emergency)".
    public static func episodes(_ h: ThermalHistory, limit: Int = 8) -> [String] {
        h.episodes.suffix(limit).reversed().map { e in
            [Format.dayMonthTime(e.start), Format.duration(e.seconds), L("peak: %@", level(e.peak))].joined(separator: " · ")
        }
    }

    public static var explanation: String {
        L("How often macOS slowed this Mac down because of heat, from the system log (kept for a few days to weeks). Repeated heavy pressure at light use points to the cooling: dust, the fan, dried thermal paste or a blocked vent; a forced sleep often means the Mac was closed in a bag while awake.")
    }
}
