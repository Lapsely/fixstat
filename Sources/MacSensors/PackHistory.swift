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
