import Foundation

/// One sample taken during a post-repair stress test.
public struct StressSample: Codable, Sendable, Equatable {
    /// Seconds since the start of the test.
    public var time: Double
    /// Hottest sensor of each group, °C.
    public var cpu: Double?
    public var gpu: Double?
    public var ssd: Double?
    public var battery: Double?
    /// mV per cell.
    public var cellVoltages: [Int]?
    /// mA, positive = charging.
    public var amperage: Int?
    public var stateOfCharge: Double?
    public var externalConnected: Bool?
    /// CPU power (W) and whether the load was still off (the idle seconds before it starts).
    public var cpuPower: Double? = nil
    public var idle: Bool? = nil
    /// What the adapter delivered (`SystemPowerIn`, W; Apple Silicon) and the USB-C contract in use
    /// (mV / mA) with the adapter's rated power: why the battery had to help (a 3 A cable caps a
    /// 20 V contract at 60 W). nil where not reported.
    public var inputWatts: Double? = nil
    public var contractMillivolts: Int? = nil
    public var contractMilliamps: Int? = nil
    public var adapterWatts: Int? = nil

    public init(time: Double, cpu: Double?, gpu: Double?, ssd: Double?, battery: Double?,
                cellVoltages: [Int]?, amperage: Int?, stateOfCharge: Double?, externalConnected: Bool?) {
        self.time = time
        self.cpu = cpu
        self.gpu = gpu
        self.ssd = ssd
        self.battery = battery
        self.cellVoltages = cellVoltages
        self.amperage = amperage
        self.stateOfCharge = stateOfCharge
        self.externalConnected = externalConnected
    }
}

/// Summary and findings of a stress test.
public struct StressTestResult: Codable, Sendable, Equatable {
    public enum Finding: Codable, Sendable, Equatable {
        /// CPU or GPU reached `limit` °C or more.
        case highChipTemperature(group: String, celsius: Double, limit: Double)
        case highBatteryTemperature(celsius: Double, limit: Double)
        /// A cell dropped below `limit` mV under load.
        case cellVoltageSag(cell: Int, millivolts: Int, limit: Int)
        /// Cell spread exceeded `limit` mV under load.
        case cellImbalance(millivolts: Int, limit: Int)
        /// On AC power the battery was still discharging (adapter cannot carry the load), with the
        /// most the adapter delivered, the contract and the adapter's rating where known.
        case adapterDeficit(averageMilliamps: Int, inputWatts: Double? = nil, contractMillivolts: Int? = nil,
                            contractMilliamps: Int? = nil, adapterWatts: Int? = nil)
        /// The test was stopped before the planned duration.
        case stoppedEarly
        /// The CPU warmed up more per watt than the healthy Macs of this model (°C/W, their highest).
        case coolingWorse(degreesPerWatt: Double, healthyHigh: Double, macs: Int)
    }

    /// Apple Silicon throttles around 100 °C by design (fanless MacBook Air reaches it
    /// under full load), so the warning starts above that range.
    public static let chipTemperatureLimit = 105.0
    public static let batteryTemperatureLimit = 45.0
    public static let cellVoltageLimit = 3300
    public static let adapterDeficitLimit = -100

    public var startedAt: Date
    public var plannedDuration: TimeInterval
    public var duration: TimeInterval
    public var loads: [String]
    public var maxCPU: Double?
    public var maxGPU: Double?
    public var maxSSD: Double?
    public var maxBattery: Double?
    public var minCellVoltage: Int?
    public var maxCellSpread: Int?
    public var socStart: Double?
    public var socEnd: Double?
    public var averageCurrent: Int?
    /// Seconds with CPU or GPU at or above the user's "hot" threshold.
    public var secondsAboveHot: Double
    public var findings: [Finding]
    /// Hottest CPU sensor's rise from idle to the end of the load per watt of CPU power added,
    /// and the CPU power idle / under load (means of the idle seconds and the last 20 s).
    public var coolingDegreesPerWatt: Double? = nil
    public var cpuPowerIdle: Double? = nil
    public var cpuPowerLoad: Double? = nil
    /// Healthy Macs of this model behind the cooling comparison (nil: no reference).
    public var coolingReference: ReferenceStat? = nil

    public var passed: Bool { findings.allSatisfy { $0 == .stoppedEarly } }

    /// Worse than every healthy Mac of the model by this share (the lab's plateau and this test differ).
    public static let coolingMargin = 0.2

    public static func analyze(samples all: [StressSample], startedAt: Date, plannedDuration: TimeInterval,
                               loads: [String], hotThreshold: Double, imbalanceThreshold: Int,
                               reference: ModelReference? = nil) -> StressTestResult {
        let idleSamples = all.filter { $0.idle == true }
        let samples = all.filter { $0.idle != true }
        func maximum(_ values: [Double?]) -> Double? { values.compactMap { $0 }.max() }
        let cells = samples.compactMap(\.cellVoltages).filter { !$0.isEmpty }
        let minCell = cells.flatMap { $0 }.min()
        let maxSpread = cells.map { ($0.max() ?? 0) - ($0.min() ?? 0) }.max()
        let currents = samples.compactMap(\.amperage)
        let averageCurrent = currents.isEmpty ? nil : currents.reduce(0, +) / currents.count

        // Time above the hot threshold, weighting each sample by the gap to the next.
        var aboveHot = 0.0
        for (index, sample) in samples.enumerated() where index + 1 < samples.count {
            let hottest = max(sample.cpu ?? -.infinity, sample.gpu ?? -.infinity)
            if hottest >= hotThreshold { aboveHot += samples[index + 1].time - sample.time }
        }

        var findings: [Finding] = []
        let maxCPU = maximum(samples.map(\.cpu))
        let maxGPU = maximum(samples.map(\.gpu))
        let maxBattery = maximum(samples.map(\.battery))
        if let t = maxCPU, t >= chipTemperatureLimit {
            findings.append(.highChipTemperature(group: "cpu", celsius: t, limit: chipTemperatureLimit))
        }
        if let t = maxGPU, t >= chipTemperatureLimit {
            findings.append(.highChipTemperature(group: "gpu", celsius: t, limit: chipTemperatureLimit))
        }
        if let t = maxBattery, t >= batteryTemperatureLimit {
            findings.append(.highBatteryTemperature(celsius: t, limit: batteryTemperatureLimit))
        }
        if let lowest = minCell, lowest < cellVoltageLimit,
           let cell = cells.compactMap({ $0.firstIndex(of: lowest) }).first {
            findings.append(.cellVoltageSag(cell: cell + 1, millivolts: lowest, limit: cellVoltageLimit))
        }
        if let spread = maxSpread, spread > imbalanceThreshold * 2 {
            findings.append(.cellImbalance(millivolts: spread, limit: imbalanceThreshold * 2))
        }
        let onAC = samples.filter { $0.externalConnected == true }.compactMap(\.amperage)
        if onAC.count >= max(5, samples.count / 2) {
            let average = onAC.reduce(0, +) / onAC.count
            if average < adapterDeficitLimit {
                let plugged = samples.filter { $0.externalConnected == true }
                let input = plugged.compactMap(\.inputWatts).max().map { ($0 * 10).rounded() / 10 }
                // The contract during most of the load (it can change while plugging in).
                let contract = plugged.last { $0.contractMillivolts != nil }
                findings.append(.adapterDeficit(averageMilliamps: average, inputWatts: input,
                                                contractMillivolts: contract?.contractMillivolts,
                                                contractMilliamps: contract?.contractMilliamps,
                                                adapterWatts: plugged.compactMap(\.adapterWatts).last))
            }
        }
        let loadStart = samples.first?.time ?? 0
        let duration = max(0, (samples.last?.time ?? 0) - loadStart)
        if duration + 5 < plannedDuration { findings.append(.stoppedEarly) }

        // Cooling: idle seconds against the last 20 s of the load, CPU load only: with the GPU loaded
        // too, the GPU's heat warms the CPU sensors and a throttled CPU draws little (an M1 Air:
        // 9.7 °C/W at 3.9 W), and the lab's references come from a CPU-only load.
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        let end = samples.filter { $0.time >= (samples.last?.time ?? 0) - 20 }
        let idleTemp = mean(idleSamples.compactMap(\.cpu)), loadTemp = mean(end.compactMap(\.cpu))
        let idlePower = mean(idleSamples.compactMap(\.cpuPower)), loadPower = mean(end.compactMap(\.cpuPower))
        var cooling: Double?
        if loads == ["cpu"], let idleTemp, let loadTemp, let idlePower, let loadPower, loadPower - idlePower >= 1, duration >= 60 {
            cooling = ((loadTemp - idleTemp) / (loadPower - idlePower) * 100).rounded() / 100
        }
        let coolingReference = reference?.coolingDegreesPerWatt.flatMap { $0.n >= ReferenceStat.minimumRecords ? $0 : nil }
        if let cooling, let stat = coolingReference, cooling > stat.high * (1 + coolingMargin) {
            findings.append(.coolingWorse(degreesPerWatt: cooling, healthyHigh: stat.high, macs: stat.n))
        }

        return StressTestResult(
            startedAt: startedAt, plannedDuration: plannedDuration, duration: duration, loads: loads,
            maxCPU: maxCPU, maxGPU: maxGPU, maxSSD: maximum(samples.map(\.ssd)), maxBattery: maxBattery,
            minCellVoltage: minCell, maxCellSpread: maxSpread,
            socStart: samples.first?.stateOfCharge, socEnd: samples.last?.stateOfCharge,
            averageCurrent: averageCurrent, secondsAboveHot: aboveHot, findings: findings,
            coolingDegreesPerWatt: cooling, cpuPowerIdle: idlePower.map { ($0 * 10).rounded() / 10 },
            cpuPowerLoad: loadPower.map { ($0 * 10).rounded() / 10 }, coolingReference: coolingReference
        )
    }
}
