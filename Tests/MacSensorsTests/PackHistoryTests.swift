import Foundation
import Testing
@testable import MacSensors
import FixStatCore

/// Values from bench dumps (lab records).
@Suite struct LifetimeTemperatureTests {
    @Test func tenthsOnM1() {
        let l = BatteryLifetime.parse(["MaximumTemperature": 456, "MinimumTemperature": 66, "AverageTemperature": 241])
        #expect(l.maximumTemperature == 45.6)
        #expect(l.minimumTemperature == 6.6)
        #expect(l.averageTemperature == 24.1)
    }

    @Test func wholeDegreesOnMac14_2() {
        let l = BatteryLifetime.parse(["MaximumTemperature": 54, "MinimumTemperature": 8, "AverageTemperature": 230])
        #expect(l.maximumTemperature == 54)
        #expect(l.minimumTemperature == 8)
        #expect(l.averageTemperature == 23.0)
    }

    @Test func implausibleAveragesAreLeftOut() {
        // Intel gauges (MacBookAir8,2, MacBookPro15,1) report 1; MacBookPro17,1 a wrapped negative value.
        #expect(BatteryLifetime.parse(["AverageTemperature": 1]).averageTemperature == nil)
        let wrapped = NSNumber(value: UInt64(18446744073709551595))
        #expect(BatteryLifetime.parse(["MaximumTemperature": 436, "AverageTemperature": wrapped]).averageTemperature == nil)
    }
}

@Suite struct PackHistoryTests {
    static func battery(minimumPackVoltage: Int?, cycles: Int = 475, lastQmax: Int? = 472) -> BatteryInfo {
        var b = BatteryInfo()
        b.cellVoltages = [3800, 3810, 3805]
        b.cycleCount = cycles
        b.cycleCountLastQmax = lastQmax
        b.lifetime = BatteryLifetime(minimumPackVoltage: minimumPackVoltage)
        return b
    }

    @Test func swollenM1PackRecordedALowVoltage() {
        let h = PackHistory(battery: Self.battery(minimumPackVoltage: 5517))
        #expect(h.lowestCellVoltage == 1839)
        #expect(h.lowVoltageRecorded)
    }

    @Test func healthyPackIsNot() {
        let h = PackHistory(battery: Self.battery(minimumPackVoltage: 8559))
        #expect(h.lowestCellVoltage == 2853)
        #expect(!h.lowVoltageRecorded)
        #expect(h.cyclesSinceQmax == 3)
        #expect(!h.qmaxStale)
    }

    @Test func oldQmaxIsStale() {
        let h = PackHistory(battery: Self.battery(minimumPackVoltage: nil, cycles: 520, lastQmax: 480))
        #expect(h.cyclesSinceQmax == 40)
        #expect(h.qmaxStale)
        #expect(h.lowestCellVoltage == nil)
    }

    @Test func intelPackWithoutTheKeys() {
        var b = Self.battery(minimumPackVoltage: nil, lastQmax: nil)
        b.cellVoltages = nil
        let h = PackHistory(battery: b)
        #expect(h.cyclesSinceQmax == nil && !h.qmaxStale && !h.lowVoltageRecorded)
    }
}

@Suite struct CycleCountLastQmaxTests {
    @Test func readFromLifetimeData() {
        var props = BatteryParsingTests.sample
        var data = props["BatteryData"] as! [String: Any]
        data["LifetimeData"] = ["CycleCountLastQmax": 375, "MinimumPackVoltage": 3760] as [String: Any]
        props["BatteryData"] = data
        props["CycleCount"] = 382
        let b = BatteryReader.parse(props, includeSerial: false)
        #expect(b.cycleCountLastQmax == 375)
        #expect(PackHistory(battery: b).cyclesSinceQmax == 7)
    }
}

@Suite struct CloneLifetimeTests {
    static var clone: [String: Any] { [
        "TotalOperatingTime": 28160, "AverageTemperature": 273,
        "TimeAtHighSoc": Data(hexString: "00000000230500001200000000000000"),
    ] }

    @Test func cloneGaugeRecordIsFlagged() {
        var b = PartsCheckTests.genuineBattery
        b.lifetime = BatteryLifetime.parse(Self.clone)
        let check = PartCheck.battery(b, model: "MacBookAir10,1", reference: PartsCheckTests.reference)
        #expect(check.items.contains { $0.id == "cloneLifetime" && $0.status == .warn })
        #expect(check.verdict == .suspicious)
    }

    @Test func genuineRecordIsNot() {
        // MacBookPro14,1 with its original pack.
        var b = PartsCheckTests.genuineBattery
        b.lifetime = BatteryLifetime.parse(["TotalOperatingTime": 62923, "AverageTemperature": 212,
                                            "TimeAtHighSoc": Data(hexString: "a8000000191100002200000000000000")])
        let check = PartCheck.battery(b, model: "MacBookAir10,1", reference: PartsCheckTests.reference)
        #expect(!check.items.contains { $0.id == "cloneLifetime" })
    }
}

@Suite struct PackAgeTests {
    static let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 10))!

    static func battery(hours: Int, samples: Int?) -> BatteryInfo {
        var b = PartsCheckTests.genuineBattery
        b.lifetime = BatteryLifetime(totalOperatingTime: hours, temperatureSamples: samples)
        return b
    }

    @Test func yearFromTheMarketingName() {
        #expect(SystemInfo.year(in: "MacBook Air (M1, 2020)") == 2020)
        #expect(SystemInfo.year(in: "MacBook Pro (13-inch, 2017, Four Thunderbolt 3 Ports)") == 2017)
        #expect(SystemInfo.year(in: "Mac mini") == nil)
    }

    @Test func operatingYears() {
        // This M1 Air: 34,109 h.
        #expect(abs((BatteryLifetime(totalOperatingTime: 34109).operatingYears ?? 0) - 3.89) < 0.01)
    }

    @Test func manufactureDateDecoding() {
        let utc = { (y: Int, m: Int, d: Int) -> Date in
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
            return c.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        }
        #expect(BatteryIdentity.manufactureDate(57381605159475) == utc(2024, 12, 4))  // MacBook Air M4
        #expect(BatteryIdentity.manufactureDate(59589184796722) == utc(2020, 10, 26)) // this M1 Air
        #expect(BatteryIdentity.manufactureDate(61779634894642) == utc(2019, 11, 8))  // MacBookAir8,2
        #expect(BatteryIdentity.manufactureDate(0) == nil)
        #expect(BatteryIdentity.manufactureDate(12345) == nil)
    }

    @Test func gaugeCannotCountLongerThanThePackExists() {
        var b = Self.battery(hours: 34109, samples: 545746)
        b.identity?.manufactureDate = BatteryIdentity.manufactureDate(57381605159475) // Dec 2024: 1.9 years before now
        let check = PartCheck.battery(b, model: "MacBookAir10,1", reference: PartsCheckTests.reference, now: Self.now)
        #expect(check.items.contains { $0.id == "gaugeClock" && $0.status == .warn })
        b.identity?.manufactureDate = BatteryIdentity.manufactureDate(59589184796722) // Oct 2020
        let fine = PartCheck.battery(b, model: "MacBookAir10,1", modelYear: 2020, reference: PartsCheckTests.reference, now: Self.now)
        #expect(!fine.items.contains { $0.id == "gaugeClock" || $0.id == "packAge" })
    }

    @Test func packOlderThanTheModelIsFlagged() {
        // A 2024 Mac with a pack that ran 4 years.
        let check = PartCheck.battery(Self.battery(hours: 35064, samples: 561024), model: "MacBookAir10,1",
                                      modelYear: 2024, reference: PartsCheckTests.reference, now: Self.now)
        #expect(check.items.contains { $0.id == "packAge" && $0.status == .warn })
        let fine = PartCheck.battery(Self.battery(hours: 34109, samples: 545746), model: "MacBookAir10,1",
                                     modelYear: 2020, reference: PartsCheckTests.reference, now: Self.now)
        #expect(!fine.items.contains { $0.id == "packAge" })
    }

    @Test func gaugeCountersMustAgree() {
        let genuine = PartCheck.battery(Self.battery(hours: 34109, samples: 545746), model: "MacBookAir10,1",
                                        reference: PartsCheckTests.reference)
        #expect(genuine.items.contains { $0.id == "gaugeCounters" && $0.status == .pass })
        let made = PartCheck.battery(Self.battery(hours: 34109, samples: 120000), model: "MacBookAir10,1",
                                     reference: PartsCheckTests.reference)
        #expect(made.items.contains { $0.id == "gaugeCounters" && $0.status == .warn })
        // Intel gauges publish no sample count: no item.
        let intel = PartCheck.battery(Self.battery(hours: 62923, samples: nil), model: "MacBookAir10,1",
                                      reference: PartsCheckTests.reference)
        #expect(!intel.items.contains { $0.id == "gaugeCounters" })
    }
}

/// TimeAtHighSoc from bench dumps.
@Suite struct ChargeHistogramTests {
    @Test func twentyEightCountersAddUpToTheOperatingTime() {
        // MacBook Air M5 (Mac17,3): 7,402 operating hours.
        let words = [0, 125, 11, 0, 0, 0, 0, 0, 40, 8, 0, 0, 0, 0, 0, 263, 4, 0, 0, 0, 0, 0, 6872, 77, 0, 0, 0, 0]
        let hex = words.map { String(format: "%08x", UInt32($0).byteSwapped) }.joined()
        let h = ChargeHistogram(lifetime: BatteryLifetime(totalOperatingTime: 7402, timeAtHighSoc: hex))
        #expect(h?.bandHours == [136, 48, 267, 6949])
        #expect(h?.totalHours == 7400)
        #expect(h.flatMap(\.highChargeShare).map { abs($0 - 0.939) < 0.001 } == true)
    }

    @Test func fourCountersAreTimeAtAHighChargeOnly() {
        // MacBookAir10,1 32360: 39,782 h, 6 / 2614 / 34 / 0.
        let h = ChargeHistogram(lifetime: BatteryLifetime(totalOperatingTime: 39782,
                                                          timeAtHighSoc: "06000000360a00002200000000000000"))
        #expect(h?.bandHours == nil)
        #expect(h?.highChargeHours == 2654)
        #expect(h?.totalHours == 39782)
    }

    @Test func implausibleBlocksAreDropped() {
        // MacBookPro13,2: 291 million operating hours.
        #expect(ChargeHistogram(lifetime: BatteryLifetime(totalOperatingTime: 291_417_542,
                                                          timeAtHighSoc: "dbe007001415c10132ef140000000000")) == nil)
    }
}

@Suite struct NotChargingTextTests {
    static func plugged() -> BatteryInfo {
        var b = BatteryInfo()
        b.externalConnected = true
        b.isCharging = false
        b.stateOfCharge = 60
        b.amperage = 0
        return b
    }

    @Test func failureModesComeFirst() {
        var b = Self.plugged()
        b.powerSource = PowerSourceState(failureModes: ["Charge FET"])
        #expect(ChargingText.notCharging(b)?.problem == true)
    }

    @Test func fullIsNormal() {
        var b = Self.plugged()
        b.fullyCharged = true
        #expect(ChargingText.notCharging(b)?.problem == false)
    }

    @Test func anAdapterAtItsLimit() {
        var b = Self.plugged()
        var adapter = AdapterInfo()
        adapter.ratedWatts = 30
        b.adapter = adapter
        var telemetry = PowerTelemetry()
        telemetry.systemPowerIn = 29_000
        b.powerTelemetry = telemetry
        #expect(ChargingText.notCharging(b)?.problem == true)
    }

    @Test func chargingOrOnBatteryNeedsNoReason() {
        var b = Self.plugged()
        b.isCharging = true
        #expect(ChargingText.notCharging(b) == nil)
        b.externalConnected = false
        b.isCharging = false
        #expect(ChargingText.notCharging(b) == nil)
    }
}

@Suite struct BankLifetimeTests {
    @Test func timeAtHighSocFromTheBanks() {
        // MacBookAir10,1 on macOS 27: the block is in each bank's LifetimeData.
        let block = Data(hexString: "000000006b1b00000500000000000000")
        let top: [String: Any] = ["CycleCount": 382, "BatteryData": ["LifetimeData": ["TotalOperatingTime": 34109]] as [String: Any]]
        let banks: [[String: Any]] = (0..<3).map { ["BankID": $0, "BatteryData": ["LifetimeData": ["TimeAtHighSoc": block]] as [String: Any]] }
        let b = BatteryReader.parse(BatteryReader.merged(top, pack: nil, banks: banks), includeSerial: false)
        #expect(ChargeHistogram(lifetime: b.lifetime)?.highChargeHours == 7024)
    }
}
