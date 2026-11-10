import Foundation
import MacSensors

/// Plain-language charging state: why a Mac on the adapter is not charging, and how the pack was
/// used (time at a high charge). Shared by both battery windows and the PDF report.
public enum ChargingText {
    /// Why the battery is not charging although the adapter is connected; nil when it charges, or
    /// on battery. `problem`: a fault rather than macOS' normal behaviour. Documented sources first
    /// (macOS' power source failure modes, the permanent failure flag, full charge), then what the
    /// readings show (an adapter at its limit, a hold near 80 %), the undocumented code last.
    public static func notCharging(_ b: BatteryInfo) -> (text: String, problem: Bool)? {
        guard b.externalConnected == true else { return nil }
        let failures = b.powerSource?.failureModes ?? []
        if !failures.isEmpty {
            return (L("The battery reports %@: it may not be charged until that is fixed.",
                      failures.map(failureMode).joined(separator: ", ")), true)
        }
        if (b.permanentFailureStatus ?? 0) != 0 || b.powerSource?.healthCondition == "Permanent Battery Failure" {
            return (L("The battery reports a permanent failure: it is not charged any more."), true)
        }
        guard b.isCharging != true else { return nil }
        if b.fullyCharged == true || b.powerSource?.isCharged == true {
            return (L("Full: macOS tops it up again only after the charge has dropped a few percent."), false)
        }
        if let input = b.powerTelemetry?.systemPowerIn, let rated = b.adapter?.ratedWatts, rated > 0,
           Double(input) / 1000 >= Double(rated) * 0.9, (b.amperage ?? 0) <= 0 {
            return (L("The adapter delivers all it can (%1$@ of %2$@) to the Mac: nothing is left for the battery. Use a stronger adapter, or check the adapter and its cable.",
                      Format.watts(Double(input) / 1000), Format.watts(Double(rated))), true)
        }
        if let soc = b.stateOfCharge, (75...85).contains(soc) {
            return (L("Probably held at about 80 %%: Optimized Battery Charging or a charge limit (Battery settings) finishes the charge later."), false)
        }
        if let temperature = b.temperature, temperature >= 40 {
            return (L("The battery is warm (%@): macOS probably pauses charging until it cools down.",
                      Format.temperature(temperature)), false)
        }
        let code = BatteryDetailText.hex(b.charger?.notChargingReason) ?? "–"
        return (L("macOS is not charging the battery (reason code %@, not documented by Apple).", code), false)
    }

    /// macOS' failure mode names (IOPSKeys.h), in the UI language.
    public static func failureMode(_ mode: String) -> String {
        switch mode {
        case "Charge Over-Temperature": return L("too hot to charge")
        case "Discharge Over-Temperature": return L("too hot to discharge")
        case "Cell Imbalance": return L("cell imbalance")
        case "Charge FET": return L("charge switch (FET) failure")
        case "Discharge FET": return L("discharge switch (FET) failure")
        case "Open Thermistor": return L("open thermistor")
        case "Fuse Blown": return L("blown fuse")
        case "Safety Over-Voltage": return L("over-voltage protection")
        case "Safety Under-Voltage": return L("under-voltage protection")
        case "Charge Over-Current": return L("charge over-current")
        case "Discharge Over-Current": return L("discharge over-current")
        case "Permanent AFE Comms", "Periodic AFE Comms", "AFE Read/Write Fail", "AFE Comparison Fail":
            return L("cell monitor (AFE) communication fault")
        case "Second Level Protection Triggered": return L("second-level protection triggered")
        case "Data Flush Fault": return L("gauge data fault")
        default: return mode
        }
    }

    // MARK: Usage

    /// "72 % · 24,800 h": share of the operating time and hours.
    public static func highCharge(_ histogram: ChargeHistogram) -> String? {
        guard let share = histogram.highChargeShare else { return nil }
        return Format.percent(share * 100) + " · " + BatteryDetailText.hours(histogram.highChargeHours)
    }

    /// "6 % · 2 % · 3 % · 89 %", lowest band first.
    public static func bands(_ histogram: ChargeHistogram) -> String? {
        guard let bands = histogram.bandHours, let total = histogram.totalHours, total > 0 else { return nil }
        return bands.map { Format.percent(Double($0) / Double(total) * 100) }.joined(separator: " · ")
    }

    /// "28 – 75 %"
    public static func today(_ b: BatteryInfo) -> String? {
        guard let low = b.dailyMinSoc, let high = b.dailyMaxSoc, high >= low, high > 0 else { return nil }
        return Format.percent(Double(low)) + " – " + Format.percent(Double(high))
    }

    /// Advice when the pack spent most of its life at a high charge.
    public static func usageFinding(_ b: BatteryInfo) -> String? {
        guard let histogram = ChargeHistogram(lifetime: b.lifetime), let share = histogram.highChargeShare,
              share >= ChargeHistogram.mostlyFullShare else { return nil }
        return L("The pack spent %@ of its life at a high charge: it was mostly kept on the adapter, which ages a battery faster. Optimized Battery Charging or a charge limit (Battery settings) helps.",
                 Format.percent(share * 100))
    }
}
