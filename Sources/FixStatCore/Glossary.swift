import Foundation

/// Short explanations of the terms FixStat shows, for the ⓘ buttons next to them: what the value
/// is, where it comes from and how to read it. Both interfaces use the same texts.
public enum Glossary {
    public enum Term: String, CaseIterable {
        // Cells
        case cellVoltage, qmax, cellResistance, cellDeviation
        // Pack
        case gauge, chemistryID, packMade, manufacturerData, cycles, health, nominalHealth, qmaxMeasured
        case permanentFailure, cellDisconnects, flashWrites
        // Lifetime
        case operatingTime, lifetimeExtremes, lowestPackVoltage, timeAtHighCharge, chargeBands, chargeToday
        // Charger
        case batteryCurrent, chargerCurrent, chargerVoltage, input, notChargingReason, reasonCodes, thermallyLimited
        // USB-C Power Delivery
        case pdContract, pdRequested, pdOffers, pdPlugIns, pdHardResets
        // Live monitor
        case systemPower, adapterInput, batteryRail, pmuRail, fanActual, fanTarget, batteryVoltage, batteryTemperature
        // Sensor check
        case macSymptoms
        // SSD
        case ssdEnduranceUsed, ssdSpare, ssdWritten, ssdEnduranceLeft, ssdPowerOnHours, ssdPowerCycles, ssdUnsafeShutdowns
        case ssdMediaErrors, ssdErrorLog, ssdReallocated, ssdPending, ssdUncorrectable, ssdCRC, ssdTrim, ssdEraseCycles
        case ssdLifeLeft, ssdRealCapacity, ssdStressTest, ssdFullTest
    }

    public static func explanation(_ term: Term) -> String {
        switch term {
        case .cellVoltage:
            return L("Voltage of each cell. The cells are in series, so at rest they should be within a few tens of millivolts of each other; a growing spread means a weak cell or balancing that does not keep up. A cell below 2.5 V has been over-discharged.")
        case .qmax:
            return L("The cell's real capacity as the gauge last measured it (mAh). The gauge measures it while the cell rests, from the voltage before and after a charge or discharge. Compared with the design capacity it shows wear; a cell clearly below the others is the weak one.")
        case .cellResistance:
            return L("The cell's internal resistance as the gauge tracks it (its weighted Ra value; Apple does not document the unit). It rises as a cell ages. Compare the cells with each other: one far above the rest sags under load and can shut the Mac down early.")
        case .cellDeviation:
            return L("How far the cell's resistance (R) and Qmax (Q) are from the average of the pack's cells. Large differences point at the weak cell.")
        case .gauge:
            return L("The fuel gauge chip in the battery pack. It measures voltage, current and temperature, counts the charge, learns the cells' capacity and keeps the pack's history. Genuine packs of a model use the same gauge chip.")
        case .chemistryID:
            return L("A number in the gauge that tells it which cell chemistry it works with, so it estimates the charge correctly. It follows the cell maker; genuine packs of a model use a few known IDs.")
        case .packMade:
            return L("When the pack was assembled, from the gauge's manufacture date. A pack much older than the Mac model is a used pack or a made-up record.")
        case .manufacturerData:
            return L("Text the pack maker wrote into the gauge: lot codes and the cell maker (e.g. ATL, Sunwoda). Clone packs often leave it empty.")
        case .cycles:
            return L("Charge cycles counted by the gauge: one cycle is the pack's full capacity used up, in any number of steps (two half discharges make one cycle). Apple rates recent MacBook batteries for 1000 cycles.")
        case .health:
            return L("The capacity the gauge measured (AppleRawMaxCapacity) as a share of the design capacity: the real wear of the pack. Below 80 % the battery is due for service.")
        case .nominalHealth:
            return L("The value macOS shows in System Settings (nominal charge capacity / design capacity). macOS smooths and rounds it, so it can differ from the measured health.")
        case .qmaxMeasured:
            return L("How many cycles ago the gauge last measured Qmax. It needs a long rest at a low and at a high charge to measure; after many cycles without a measurement the health value may be out of date. A full charge, a few hours' rest, then a discharge to a low charge and another rest refresh it.")
        case .permanentFailure:
            return L("The gauge's permanent failure flags. Anything other than 0 means the gauge has switched the pack off for good to protect it (e.g. cell imbalance, overheating, a blown fuse); the pack has to be replaced, it cannot be reset.")
        case .cellDisconnects:
            return L("How often the gauge saw a cell disconnect. It should be 0; anything else points at a loose connection inside the pack or at its connector.")
        case .flashWrites:
            return L("How often the gauge has written its data memory. It grows slowly with use; a very low count on a pack that looks old can mean a new or reset gauge.")
        case .operatingTime:
            return L("Hours the gauge has been powered and counting. It does not count while the pack is disconnected or in shipping mode, so it is a lower bound of the pack's age.")
        case .lifetimeExtremes:
            return L("Extremes the gauge recorded over the pack's whole life; they are never reset. A very high temperature means the pack was overheated at least once.")
        case .lowestPackVoltage:
            return L("The lowest pack voltage the gauge ever saw, and per cell. Below 2.5 V per cell means a deep discharge, or a reading taken while the pack was disconnected during a repair.")
        case .timeAtHighCharge:
            return L("Share of the pack's life it spent at a high charge, counted by the gauge. Sitting near full all the time ages the cells faster; a Mac that lives on the adapter shows a high share.")
        case .chargeBands:
            return L("Hours the gauge counted in each charge band, from low to high charge. Apple does not document where the bands begin and end.")
        case .chargeToday:
            return L("The lowest and the highest charge of the day as the gauge records them.")
        case .batteryCurrent:
            return L("Current flowing into the battery (+, charging) or out of it (−, the Mac runs on the battery), averaged by the gauge.")
        case .chargerCurrent:
            return L("The current the charger is set to deliver to the battery now. It drops near a full charge and when the battery is warm.")
        case .chargerVoltage:
            return L("The voltage the charger charges the pack to (its full-charge voltage). It is lowered for a charge limit or a warm battery.")
        case .input:
            return L("Power coming in from the adapter as the Mac measures it at its power input (voltage × current).")
        case .notChargingReason:
            return L("Apple's code for why the charger is not charging (a bit field, 0 = charging is allowed). The sentence above the rows names the usual causes in plain words.")
        case .reasonCodes:
            return L("Apple's undocumented codes for why charging is slowed or blocked, shown as reported. 0 means none; any other value means the charger is held back for a reason the gauge or the power controller reported.")
        case .thermallyLimited:
            return L("How long charging was slowed because the battery or the Mac was too warm.")
        case .pdContract:
            return L("The USB-C Power Delivery profile the Mac and the adapter agreed on: voltage and maximum current. A 5 V contract from an adapter that offers more means the cable, the port or the adapter is not working properly.")
        case .pdRequested:
            return L("What the Mac asked the adapter for within the contract: the current it expects to draw.")
        case .pdOffers:
            return L("Every profile the adapter offers. Genuine Apple adapters offer a known set per model; FixStat compares them in the originality check.")
        case .pdPlugIns:
            return L("How often the port controller saw an adapter plugged in and removed. Many removals without anyone unplugging point at a loose cable or a worn port.")
        case .systemPower:
            return L("PSTR: the power the whole Mac draws, measured by the SMC at the system's main power rail. On battery it is what drains the battery; on the adapter it also includes the charging power.")
        case .adapterInput:
            return L("PDTR: the power coming in from the adapter (DC in). Zero on battery. With the adapter connected it is the system's power plus what goes into the battery.")
        case .batteryRail:
            return L("PPBR: the power on the battery's rail. Positive values flow out of the battery to the Mac; while charging the battery takes power instead.")
        case .pmuRail:
            return L("One output of the power management IC (PMU): a buck converter (b) or an LDO regulator (l) feeding one part of the board. Which part depends on the chip (on the M1, buck 0 feeds the performance CPU cores and buck 1 the GPU). A rail that draws current at idle while the others are quiet points at a leak or a short on that part of the board.")
        case .fanActual:
            return L("The fan's real speed, measured from its tachometer signal (F…Ac). 0 rpm while the fan visibly spins means the tachometer signal does not reach the SMC: fan connector, the fan or its tach line.")
        case .fanTarget:
            return L("The speed the SMC asks the fan for (F…Tg). The real speed should follow it within a few hundred rpm. Far below: a worn or dirty fan. Far above, or full speed at target 0: the SMC has lost control of the fan (PWM line, connector, drive circuit).")
        case .batteryVoltage:
            return L("The pack's voltage as the gauge measures it: the sum of the cells in series. It sags under load and rises while charging.")
        case .batteryTemperature:
            return L("The battery's temperature from the gauge's sensor. Charging slows above about 40 °C, and a hot pack ages faster.")
        case .macSymptoms:
            return L("What macOS and the SMC do when they miss a sensor or see a fault: fans at high speed although the Mac is cool, a CPU speed limit below 100 % (macOS runs the CPU slower; read from pmset -g therm), or kernel_task taking the CPU. A missing or broken sensor is a common cause, but a fan, battery or power adapter fault causes the same.")
        case .ssdEnduranceUsed:
            return L("The share of the SSD's rated write endurance used up, reported by the drive itself (NVMe \"percentage used\"). NAND cells wear with every write; at 100 % the rated endurance is reached, and most drives keep working for a while but are past their warranty value.")
        case .ssdSpare:
            return L("Spare NAND blocks the SSD still has to replace worn-out ones. It starts at 100 % and drops as blocks fail; a low value means the drive is running out of replacements.")
        case .ssdWritten:
            return L("All data the computer has written to the drive in its life. Compared with the endurance used it shows how fast the drive wears. \"Estimate\" means the drive counts in sectors and the size is calculated from them.")
        case .ssdEnduranceLeft:
            return L("How much more data can be written before the rated endurance is reached, if the drive keeps wearing as it has so far (data written × life left ÷ life used). Shown from 5 % wear, because the drive reports wear in whole percent.")
        case .ssdPowerOnHours:
            return L("Hours the drive has been powered on in its life.")
        case .ssdPowerCycles:
            return L("How often the drive was powered on.")
        case .ssdUnsafeShutdowns:
            return L("Power losses without a proper shutdown: forced shutdowns, a battery that ran flat, or a drive in an enclosure unplugged without ejecting. Each one risks the data being written at that moment.")
        case .ssdMediaErrors:
            return L("Data the SSD could not read back correctly even with its error correction. Should be 0; any other value means data was lost and the NAND is failing.")
        case .ssdErrorLog:
            return L("Entries in the drive's own error log. They are often harmless (e.g. commands the drive does not support), so judge them together with media errors.")
        case .ssdReallocated:
            return L("Sectors the drive found bad and replaced with spare ones. A few on an old hard disk are tolerated; a growing number means the surface or the NAND is failing.")
        case .ssdPending:
            return L("Sectors that could not be read and wait to be replaced the next time they are written. Any value above 0 means unreadable data right now.")
        case .ssdUncorrectable:
            return L("Errors the drive could not correct while reading. Should be 0.")
        case .ssdCRC:
            return L("Transfer errors on the cable between the drive and the computer (or the USB adapter). They point at the cable, the connector or the enclosure, not at the drive itself.")
        case .ssdTrim:
            return L("TRIM tells the SSD which blocks are free, so it can keep them ready. macOS turns it on by itself only for Apple's SSDs; without it a third-party SSD gets slower and wears faster (\"sudo trimforce enable\" turns it on).")
        case .ssdEraseCycles:
            return L("How often the NAND blocks have been erased, on average and lowest / highest. NAND survives a limited number of erase cycles (typically a few thousand for TLC); a large gap between lowest and highest means uneven wear.")
        case .ssdLifeLeft:
            return L("The life left that the drive's maker reports in its own SMART attribute. FixStat shows it only for drive families whose wear counter it knows; for others it shows the evidence instead of a guess.")
        case .ssdRealCapacity:
            return CapacityCheckText.explanation
        case .ssdStressTest:
            return L("Writes a test file to free space, reads it back and compares every byte. Finds data corruption, I/O errors and stalling areas that point to failing NAND. Only free space can be tested, and the test uses some of the SSD's write endurance.")
        case .ssdFullTest:
            return L("Reads the entire SSD — including used space and the system partitions — and maps unreadable and slow areas, then runs the write–verify test on free space. The scan only reads. macOS asks for an administrator password; FixStat never sees or stores it.")
        case .pdHardResets:
            return L("USB-C Power Delivery hard resets: the Mac and the adapter restarted their negotiation. A few are normal; many point at a bad cable, adapter or port.")
        }
    }

    /// The explanation that fits a live monitor channel (nil for temperature sensors: their names say it).
    public static func term(forLiveChannel id: String, group: LiveMonitor.Group) -> Term? {
        switch id {
        case "smc:PSTR": return .systemPower
        case "smc:PDTR": return .adapterInput
        case "smc:PPBR": return .batteryRail
        case "battery:voltage": return .batteryVoltage
        case "battery:amperage": return .batteryCurrent
        case "battery:temperature": return .batteryTemperature
        default: break
        }
        if id.hasPrefix("battery:cell:") { return .cellVoltage }
        if id.hasPrefix("fan:") { return id.hasSuffix(":target") ? .fanTarget : .fanActual }
        return group == .rails ? .pmuRail : nil
    }

    /// The explanation for a SMART row of `SSDText` (matched by its localized title).
    public static func term(forSSDRow title: String) -> Term? {
        let terms: [(String, Term)] = [
            (L("Endurance used"), .ssdEnduranceUsed), (L("Available spare"), .ssdSpare),
            (L("Data written"), .ssdWritten), (L("Data written (estimate)"), .ssdWritten),
            (L("Endurance left"), .ssdEnduranceLeft), (L("Power-on hours"), .ssdPowerOnHours),
            (L("Power cycles"), .ssdPowerCycles), (L("Unsafe shutdowns"), .ssdUnsafeShutdowns),
            (L("Media errors"), .ssdMediaErrors), (L("Error log entries"), .ssdErrorLog),
            (L("Reallocated sectors"), .ssdReallocated), (L("Pending sectors"), .ssdPending),
            (L("Uncorrectable sectors"), .ssdUncorrectable), (L("Interface CRC errors"), .ssdCRC),
            ("TRIM", .ssdTrim), (L("NAND erase cycles"), .ssdEraseCycles), (L("Life left"), .ssdLifeLeft),
        ]
        return terms.first { $0.0 == title }?.1
    }
}
