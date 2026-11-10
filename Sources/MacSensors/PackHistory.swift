import Foundation

/// What the gauge's own records say about the pack's past: the lowest voltage it ever saw, and how
/// long ago it last measured the cell capacities (the base of the health value).
public struct PackHistory: Sendable, Equatable {
    /// Lowest voltage per cell the gauge recorded over the pack's life (`MinimumPackVoltage` divided
    /// by the series cells), mV. Bench Macs that were never opened read 2.85 – 3.5 V. Low values came
    /// only from Macs with a history: a MacBookAir10,1 with degassed swollen cells and a new board
    /// (1.84 V), one whose pack was serviced (1.25 V) and a liquid-damaged MacBookPro17,1 after repair
    /// (2.36 V). The gauge keeps a single pack voltage, so a deep discharge and a reading taken while
    /// the pack was disconnected during a repair cannot be told apart.
    public let lowestCellVoltage: Int?
    /// Below `CellAnalysis.minimumVoltage` (2.5 V) at some point.
    public let lowVoltageRecorded: Bool
    /// Cycles since the gauge last measured Qmax (`CycleCount − CycleCountLastQmax`).
    public let cyclesSinceQmax: Int?
    /// At least `staleQmaxCycles`: the health value rests on an old measurement.
    public let qmaxStale: Bool

    /// Bench packs were measured within the last 0 – 3 cycles.
    public static let staleQmaxCycles = 30

    public init(battery: BatteryInfo) {
        let cells = battery.cellVoltages?.count ?? 0
        if let pack = battery.lifetime?.minimumPackVoltage, pack > 0, cells > 0 {
            lowestCellVoltage = pack / cells
        } else {
            lowestCellVoltage = nil
        }
        lowVoltageRecorded = lowestCellVoltage.map { $0 < CellAnalysis.minimumVoltage } ?? false
        if let cycles = battery.cycleCount, let last = battery.cycleCountLastQmax, last > 0, cycles >= last {
            cyclesSinceQmax = cycles - last
        } else {
            cyclesSinceQmax = nil
        }
        qmaxStale = (cyclesSinceQmax ?? 0) >= Self.staleQmaxCycles
    }
}

/// How long the pack sat at a high charge, from the gauge's `TimeAtHighSoc` block of 32-bit counters
/// (hours). M2 and later gauges (bq40z651) keep 28 counters that add up to the operating time
/// (Mac14,2: 34,570 of 34,568 h; MacBook Air M5: 7,400 of 7,402 h): four groups of seven, read here
/// as four charge bands of seven temperature bins each, the last group being the highest charge
/// (it holds most of the hours on every bench Mac, 68 – 93 %; the band limits are not published).
/// Older gauges (M1, Intel) keep four counters of time at a high charge only.
public struct ChargeHistogram: Sendable, Equatable {
    /// Hours per charge band, lowest first (28-counter gauges only).
    public let bandHours: [Int]?
    /// Hours at a high charge: the highest band, or every counter of the older layout.
    public let highChargeHours: Int
    /// The hours the counters cover (28 counters: their sum; older layout: the operating time).
    public let totalHours: Int?

    public var highChargeShare: Double? {
        guard let total = totalHours, total > 0 else { return nil }
        return Double(highChargeHours) / Double(total)
    }

    /// Reported from this share of the operating time: "kept plugged in at full charge".
    public static let mostlyFullShare = 0.8

    public init?(lifetime: BatteryLifetime?) {
        guard let hex = lifetime?.timeAtHighSoc, hex.count % 8 == 0, !hex.isEmpty else { return nil }
        var words: [Int] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 8)
            guard let value = UInt32(hex[index..<next], radix: 16) else { return nil }
            words.append(Int(value.byteSwapped)) // little endian in the block
            index = next
        }
        if words.count == 28 {
            let bands = stride(from: 0, to: 28, by: 7).map { words[$0..<($0 + 7)].reduce(0, +) }
            bandHours = bands
            highChargeHours = bands[3]
            totalHours = bands.reduce(0, +)
        } else if words.count == 4 {
            bandHours = nil
            highChargeHours = words.reduce(0, +)
            totalHours = lifetime?.totalOperatingTime
        } else {
            return nil
        }
        // A wrapped or made-up block (MacBookPro13,2: 291 million hours) says nothing.
        guard let total = totalHours, total > 0, total < 200_000, highChargeHours <= total + 24 else { return nil }
    }
}
