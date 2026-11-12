import Foundation
import MacSensors

/// Feedback and part reports through the project's Google Form. FixStat only builds a prefilled form
/// address and opens it in the browser: nothing is sent until the user presses Submit there, and the
/// user sees every field first. Serial numbers, lot codes and identifiers are never put in the form.
public enum FeedbackForm {
    public enum Kind: String {
        case unknownBattery = "Unknown battery"
        case unknownAdapter = "Unknown adapter"
        case wrongSensor = "Wrong sensor reading"
        case bug = "Bug"
        case idea = "Idea"
        case other = "Other"
    }

    static let address = "https://docs.google.com/forms/d/e/1FAIpQLScB8r8yP8uynWgaq9qx3PoMOUHjOlPPeGfnBTlPQDzOu7sIig/viewform"

    /// Field ids of the form (from its prefilled link).
    enum Entry {
        static let type = "entry.1317305820"
        static let model = "entry.2025802587"
        static let macOS = "entry.596418824"
        static let app = "entry.292060651"
        static let details = "entry.1251752089"
    }

    /// Longest details text put into the address (browsers and Google accept far longer addresses,
    /// but a report never needs more).
    static let detailsLimit = 1500

    public static func url(kind: Kind?, model: String, macOS: String, appVersion: String, details: String = "") -> URL? {
        let components = URLComponents(string: address)
        var items = [URLQueryItem(name: "usp", value: "pp_url")]
        if let kind { items.append(URLQueryItem(name: Entry.type, value: kind.rawValue)) }
        items.append(URLQueryItem(name: Entry.model, value: model))
        items.append(URLQueryItem(name: Entry.macOS, value: macOS))
        items.append(URLQueryItem(name: Entry.app, value: appVersion))
        let trimmed = details.count > detailsLimit ? String(details.prefix(detailsLimit)) + "…" : details
        if !trimmed.isEmpty { items.append(URLQueryItem(name: Entry.details, value: trimmed)) }
        guard var parts = components else { return nil }
        parts.queryItems = items
        // URLComponents leaves "+" alone, which a form reads as a space.
        let query = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        parts.percentEncodedQuery = query
        return parts.url
    }

    /// General feedback (Settings): the user picks the type in the form.
    public static func general(system: SystemInfo) -> URL? {
        url(kind: nil, model: system.model, macOS: system.osVersion, appVersion: appVersion)
    }

    /// A battery or adapter report: offered when the originality check could not confirm the part.
    public static func battery(_ b: BatteryInfo, check: PartCheck, system: SystemInfo) -> URL? {
        url(kind: .unknownBattery, model: system.model, macOS: system.osVersion, appVersion: appVersion,
            details: batteryDetails(b, check: check, system: system))
    }

    public static func adapter(_ b: BatteryInfo, check: PartCheck, system: SystemInfo) -> URL? {
        url(kind: .unknownAdapter, model: system.model, macOS: system.osVersion, appVersion: appVersion,
            details: adapterDetails(b, check: check))
    }

    /// The part check is worth a report when it could not confirm the part.
    /// `-FixStatSamplePartReport YES` offers it for every part (checking the button on a Mac with genuine parts).
    public static func offersReport(_ check: PartCheck) -> Bool {
        check.verdict != .consistent || UserDefaults.standard.bool(forKey: "FixStatSamplePartReport")
    }

    static var appVersion: String { "\(AboutInfo.version) (\(AboutInfo.build))" }

    /// What parts.json keeps for a battery, plus the check's evidence (ids are stable, not localized).
    static func batteryDetails(_ b: BatteryInfo, check: PartCheck, system: SystemInfo) -> String {
        var lines: [String] = []
        if let name = system.marketingName { lines.append("mac: \(name)") }
        lines.append("gauge: \(b.gaugeDeviceName ?? "-")")
        lines.append("chemistry: \(b.identity?.chemistryID.map(String.init) ?? "-")")
        lines.append("design capacity: \(b.designCapacity.map { "\($0) mAh" } ?? "-")")
        lines.append("cells: \(b.cellVoltages.map { String($0.count) } ?? "-")")
        // Only the last ManufacturerData string (the cell maker): the others are lot codes.
        lines.append("cell maker: \(b.identity?.manufacturerStrings.last ?? "-")")
        if let qmax = b.cellQmax, !qmax.isEmpty { lines.append("qmax: " + qmax.map(String.init).joined(separator: " / ") + " mAh") }
        if let cycles = b.cycleCount { lines.append("cycles: \(cycles)") }
        if let made = b.identity?.manufactureDate { lines.append("pack made: \(day(made))") }
        lines.append(evidence(check))
        return lines.joined(separator: "\n")
    }

    static func adapterDetails(_ b: BatteryInfo, check: PartCheck) -> String {
        guard let a = b.adapter else { return evidence(check) }
        var lines: [String] = []
        lines.append("name: \((a.name ?? "-").trimmingCharacters(in: .whitespaces))")
        lines.append("manufacturer: \(a.manufacturer ?? "-")")
        lines.append("id: \(a.model ?? "-")")
        if let watts = a.ratedWatts { lines.append("watts: \(watts)") }
        if let firmware = a.firmwareVersion { lines.append("firmware: \(firmware)") }
        if let hardware = a.hardwareVersion { lines.append("hardware: \(hardware)") }
        if let family = a.familyCode { lines.append("family: " + String(format: "0x%x", family)) }
        if let offered = b.powerDelivery?.offeredProfiles, !offered.isEmpty {
            lines.append("profiles: " + offered.map { "\(($0.maxVoltage ?? 0) / 1000)V \(Double($0.maxCurrent ?? 0) / 1000)A" }
                .joined(separator: ", "))
        }
        lines.append(evidence(check))
        return lines.joined(separator: "\n")
    }

    static func evidence(_ check: PartCheck) -> String {
        "verdict: \(check.verdict.rawValue)\n" + check.items
            .filter { $0.id != "serial" && $0.id != "adapter.serial" }
            .map { "\($0.status.rawValue) \($0.id)" + ($0.detail.isEmpty || $0.id == "manufacturerData" ? "" : ": \($0.detail)") }
            .joined(separator: "\n")
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public enum FeedbackText {
    public static var reportHelp: String {
        L("Opens a prefilled Google Form in your browser: you see every field, and nothing is sent until you press Submit. Serial numbers are never included.")
    }
}
