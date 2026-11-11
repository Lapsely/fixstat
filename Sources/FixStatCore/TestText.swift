import Foundation
import MacSensors

/// Localized texts for test results (shared by the window and the PDF report).
public enum TestText {
    public static func finding(_ finding: StressTestResult.Finding) -> String {
        switch finding {
        case let .highChipTemperature(group, celsius, limit):
            let name = group == "gpu" ? "GPU" : "CPU"
            return L("%@ reached %@ (limit %@)", name, Format.temperature(celsius), Format.temperature(limit, digits: 0))
        case let .highBatteryTemperature(celsius, limit):
            return L("Battery reached %@ (limit %@)", Format.temperature(celsius), Format.temperature(limit, digits: 0))
        case let .cellVoltageSag(cell, millivolts, limit):
            return L("Cell %lld dropped to %@ under load (limit %@)", cell, Format.volts(millivolts: millivolts, digits: 3), Format.volts(millivolts: limit, digits: 1))
        case let .cellImbalance(millivolts, limit):
            return L("Cell spread reached %@ under load (limit %@)", Format.millivolts(millivolts), Format.millivolts(limit))
        case let .adapterDeficit(average, input, millivolts, milliamps, rated):
            var text = L("On the power adapter the battery was still discharging (average %@) — adapter, cable or charging circuit may be weak", Format.milliamps(average))
            if let input {
                text += " " + L("The adapter delivered at most %@.", Format.watts(input, digits: 1))
            }
            if let millivolts, let milliamps {
                let contract = Double(millivolts) * Double(milliamps) / 1_000_000
                text += " " + L("Contract: %@ · %@ (%@).", Format.volts(millivolts: millivolts, digits: 0),
                                Format.amps(milliamps: milliamps), Format.watts(contract))
                // A USB-C cable without an e-marker carries 3 A: 20 V · 3 A = 60 W whatever the adapter.
                if milliamps <= 3000, let rated, Double(rated) > contract + 5 {
                    text += " " + L("The %@ adapter is held at %@: the cable is probably a 3 A cable, use a 5 A (100 W or more) cable.",
                                    Format.watts(Double(rated)), Format.watts(contract))
                }
            }
            return text
        case .stoppedEarly:
            return L("Test was stopped before the planned duration")
        case let .coolingWorse(degreesPerWatt, high, macs):
            return L("The CPU heats up %1$@ per watt, more than healthy Macs of this model (up to %2$@, %3$lld Macs): thermal paste, heatsink seating, the fan or dust.",
                     coolingFigure(degreesPerWatt), coolingFigure(high), macs)
        }
    }

    /// "1.9 °C/W"
    public static func coolingFigure(_ value: Double) -> String {
        Format.number(value, digits: 2) + "\u{00A0}°C/W"
    }

    public static func summaryRows(_ r: StressTestResult) -> [(String, String)] {
        var rows: [(String, String)] = [
            (L("Duration"), Format.minutesSeconds(r.duration)),
            (L("Highest CPU temperature"), r.maxCPU.map { Format.temperature($0) } ?? "–"),
            (L("Highest GPU temperature"), r.maxGPU.map { Format.temperature($0) } ?? "–"),
            (L("Highest SSD temperature"), r.maxSSD.map { Format.temperature($0) } ?? "–"),
            (L("Highest battery temperature"), r.maxBattery.map { Format.temperature($0) } ?? "–"),
            (L("Time at or above hot threshold"), Format.minutesSeconds(r.secondsAboveHot)),
        ]
        if let v = r.minCellVoltage {
            rows.append((L("Lowest cell voltage"), Format.volts(millivolts: v, digits: 3)))
        }
        if let s = r.maxCellSpread {
            rows.append((L("Largest cell spread"), Format.millivolts(s)))
        }
        if let cooling = r.coolingDegreesPerWatt {
            var text = coolingFigure(cooling)
            if let idle = r.cpuPowerIdle, let load = r.cpuPowerLoad {
                text += " · " + L("CPU %1$@ → %2$@", Format.watts(idle, digits: 1), Format.watts(load, digits: 1))
            }
            if let stat = r.coolingReference {
                text += " · " + L("healthy Macs %1$@ – %2$@", coolingFigure(stat.low), coolingFigure(stat.high))
            }
            rows.append((L("Cooling"), text))
        }
        if let a = r.socStart, let b = r.socEnd {
            rows.append((L("Battery charge"), "\(Format.percent(a)) → \(Format.percent(b))"))
        }
        if let c = r.averageCurrent {
            rows.append((L("Average battery current"), Format.milliamps(c)))
        }
        return rows
    }
}
