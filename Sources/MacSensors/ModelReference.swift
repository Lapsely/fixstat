import Foundation

/// Bench values of healthy Macs per model (`SensorMaps/model-reference.json`), written by the lab's
/// merge: rebuilt from every healthy record each time, one value per Mac (its latest record). FixStat
/// compares a Mac with them once a model has `ReferenceStat.minimumRecords`.
public struct ModelReferences: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var note = "Bench values of healthy Macs per model: idle / load temperatures per sensor group (°C), idle power with the display off (W), CPU power under the all-core load (W), cooling (°C per W), idle rail currents (A), drain while shut down (mA). One value per Mac; rebuilt by the lab merge."
    public var models: [String: ModelReference] = [:]

    public init(models: [String: ModelReference] = [:]) {
        self.models = models
    }

    public static func load(from url: URL) -> ModelReferences? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelReferences.self, from: data)
    }
}

public struct ModelReference: Codable, Sendable, Equatable {
    /// Healthy Macs behind these values.
    public var macs: Int
    /// Sensor group → hottest mean while idle / under the all-core load.
    public var idleTemperature: [String: ReferenceStat] = [:]
    public var loadTemperature: [String: ReferenceStat] = [:]
    /// Idle system power with the backlight off: on battery where measured, else on the adapter
    /// while barely charging.
    public var idleDisplayOffW: ReferenceStat?
    public var cpuLoadW: ReferenceStat?
    /// Rise of the hottest CPU sensor per watt of CPU power, and the die above the heatsink per
    /// watt (Intel MacBooks with heatsink sensors).
    public var coolingDegreesPerWatt: ReferenceStat?
    public var dieAboveHeatsinkPerWatt: ReferenceStat?
    /// Rail → current (A) with the display off (on battery where measured).
    public var idleRailAmps: [String: ReferenceStat] = [:]
    public var offDrainMilliamps: ReferenceStat?

    public init(macs: Int) {
        self.macs = macs
    }
}

/// A value across healthy Macs.
public struct ReferenceStat: Codable, Sendable, Equatable {
    public var n: Int
    public var median: Double
    public var low: Double
    public var high: Double

    /// FixStat judges a value only against this many Macs or more.
    public static let minimumRecords = 3

    public init(n: Int, median: Double, low: Double, high: Double) {
        self.n = n
        self.median = median
        self.low = low
        self.high = high
    }

    /// nil for no values; rounded to `digits`.
    public static func of(_ values: [Double], digits: Int = 2) -> ReferenceStat? {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return nil }
        let scale = pow(10, Double(digits))
        func round(_ v: Double) -> Double { (v * scale).rounded() / scale }
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        return ReferenceStat(n: sorted.count, median: round(median), low: round(sorted[0]), high: round(sorted[sorted.count - 1]))
    }

    /// How far `value` lies outside the healthy range, as a share of the median (0 inside it).
    public func excess(_ value: Double) -> Double {
        let base = max(abs(median), 1e-6)
        if value > high { return (value - high) / base }
        if value < low { return (value - low) / base }
        return 0
    }
}
