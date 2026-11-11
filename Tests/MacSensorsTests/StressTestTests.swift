import Foundation
import Testing
@testable import MacSensors
import FixStatCore

@Suite struct StressTestTests {
    func sample(_ t: Double, cpu: Double = 60, gpu: Double = 50, battery: Double = 32,
                cells: [Int] = [3900, 3910, 3905], amperage: Int = -2000, soc: Double = 80,
                ac: Bool = false) -> StressSample {
        StressSample(time: t, cpu: cpu, gpu: gpu, ssd: 40, battery: battery, cellVoltages: cells,
                     amperage: amperage, stateOfCharge: soc, externalConnected: ac)
    }

    func analyze(_ samples: [StressSample], planned: TimeInterval = 10) -> StressTestResult {
        .analyze(samples: samples, startedAt: Date(), plannedDuration: planned, loads: ["cpu"],
                 hotThreshold: 55, imbalanceThreshold: 50)
    }

    @Test func healthyRunPasses() {
        let result = analyze((0...10).map { sample(Double($0), soc: 80 - Double($0) * 0.1) })
        #expect(result.passed)
        #expect(result.findings.isEmpty)
        #expect(result.maxCPU == 60)
        #expect(result.secondsAboveHot == 10)
        #expect(result.socStart == 80)
        #expect(result.averageCurrent == -2000)
        #expect(result.maxCellSpread == 10)
    }

    @Test func fanlessThrottlingIsNotAProblem() {
        let result = analyze((0...10).map { sample(Double($0), cpu: 100.1, gpu: 95) })
        #expect(result.passed)
    }

    @Test func reportsProblems() {
        var samples = (0...10).map { sample(Double($0)) }
        samples[5] = sample(5, cpu: 107, battery: 47, cells: [3250, 3400, 3395])
        let result = analyze(samples)
        #expect(!result.passed)
        #expect(result.findings.contains(.highChipTemperature(group: "cpu", celsius: 107, limit: 105)))
        #expect(result.findings.contains(.highBatteryTemperature(celsius: 47, limit: 45)))
        #expect(result.findings.contains(.cellVoltageSag(cell: 1, millivolts: 3250, limit: 3300)))
        #expect(result.findings.contains(.cellImbalance(millivolts: 150, limit: 100)))
    }

    @Test func adapterDeficitOnlyOnAC() {
        let onAC = analyze((0...10).map { sample(Double($0), amperage: -600, ac: true) })
        #expect(onAC.findings.contains { if case .adapterDeficit(averageMilliamps: -600, _, _, _, _) = $0 { true } else { false } })
        let charging = analyze((0...10).map { sample(Double($0), amperage: 800, ac: true) })
        #expect(charging.findings.isEmpty)
    }

    @Test func stoppedEarly() {
        let result = analyze((0...10).map { sample(Double($0)) }, planned: 120)
        #expect(result.findings == [.stoppedEarly])
        #expect(result.passed)
    }
}

@Suite struct CoolingTests {
    static func run(load: Double, idleTemp: Double = 40, loadTemp: Double = 80) -> [StressSample] {
        var samples: [StressSample] = []
        for t in 0..<8 {
            var s = StressSample(time: Double(t), cpu: idleTemp, gpu: nil, ssd: nil, battery: 30, cellVoltages: nil,
                                 amperage: 0, stateOfCharge: 80, externalConnected: false)
            s.cpuPower = 0.5
            s.idle = true
            samples.append(s)
        }
        for t in 8..<128 {
            var s = StressSample(time: Double(t), cpu: loadTemp, gpu: nil, ssd: nil, battery: 30, cellVoltages: nil,
                                 amperage: -2000, stateOfCharge: 80, externalConnected: false)
            s.cpuPower = load
            samples.append(s)
        }
        return samples
    }

    @Test func coolingFromIdleAndLoad() {
        let r = StressTestResult.analyze(samples: Self.run(load: 20.5), startedAt: Date(), plannedDuration: 120, loads: ["cpu"],
                                         hotThreshold: 95, imbalanceThreshold: 50)
        #expect(r.coolingDegreesPerWatt == 2)    // (80 − 40) / (20.5 − 0.5)
        #expect(r.duration == 119)
        #expect(!r.findings.contains(.stoppedEarly))
        let both = StressTestResult.analyze(samples: Self.run(load: 20.5), startedAt: Date(), plannedDuration: 120,
                                            loads: ["cpu", "gpu"], hotThreshold: 95, imbalanceThreshold: 50)
        #expect(both.coolingDegreesPerWatt == nil)
    }

    @Test func worseThanHealthyMacs() {
        var reference = ModelReference(macs: 3)
        reference.coolingDegreesPerWatt = ReferenceStat(n: 3, median: 1.5, low: 1.4, high: 1.6)
        let r = StressTestResult.analyze(samples: Self.run(load: 20.5), startedAt: Date(), plannedDuration: 120, loads: ["cpu"],
                                         hotThreshold: 95, imbalanceThreshold: 50, reference: reference)
        #expect(r.findings.contains(.coolingWorse(degreesPerWatt: 2, healthyHigh: 1.6, macs: 3)))
        reference.coolingDegreesPerWatt?.n = 2
        let few = StressTestResult.analyze(samples: Self.run(load: 20.5), startedAt: Date(), plannedDuration: 120, loads: ["cpu"],
                                           hotThreshold: 95, imbalanceThreshold: 50, reference: reference)
        #expect(few.coolingReference == nil && !few.findings.contains { if case .coolingWorse = $0 { true } else { false } })
    }
}

@Suite struct IdlePowerReferenceTests {
    static func result(watts: Double, charging: Int = -400, rails: [String: Double] = [:]) -> IdlePowerResult {
        var r = IdlePowerResult(date: Date(), samples: Array(repeating: watts, count: 20), cpu: 0.02, onBattery: true, source: "smc")
        r.batteryMilliamps = charging
        r.railAmps = rails
        r.externalDisplays = 0
        return r
    }

    static var reference: ModelReference {
        var m = ModelReference(macs: 3)
        m.idleDisplayOffW = ReferenceStat(n: 3, median: 4.3, low: 4.1, high: 4.6)
        m.idleRailAmps = ["MVR": ReferenceStat(n: 3, median: 0.15, low: 0.12, high: 0.18)]
        return m
    }

    @Test func modelReferencesWin() {
        let normal = DrainText.idlePowerVerdict(Self.result(watts: 4.4), reference: PowerReference(), model: "Mac14,2", models: Self.reference)
        #expect(normal.problem == false)
        let high = DrainText.idlePowerVerdict(Self.result(watts: 7), reference: PowerReference(), model: "Mac14,2", models: Self.reference)
        #expect(high.problem == true)
    }

    @Test func chargingIsNotJudged() {
        let v = DrainText.idlePowerVerdict(Self.result(watts: 7, charging: 3000), reference: PowerReference(), model: "Mac14,2", models: Self.reference)
        #expect(v.problem == nil)
    }

    @Test func aRailAboveHealthyMacs() {
        let r = Self.result(watts: 4.4, rails: ["MVR": 0.6])
        #expect(DrainText.railFindings(r, models: Self.reference).count == 1)
        #expect(DrainText.idlePowerVerdict(r, reference: PowerReference(), model: "Mac14,2", models: Self.reference).problem == true)
        #expect(DrainText.railFindings(Self.result(watts: 4.4, rails: ["MVR": 0.19]), models: Self.reference).isEmpty)
    }
}
