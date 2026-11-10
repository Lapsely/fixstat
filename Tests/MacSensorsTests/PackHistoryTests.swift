import Foundation
import Testing
@testable import MacSensors

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
