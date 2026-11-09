import CMacSensors
import Foundation
import IOKit

/// One attribute of the ATA SMART data structure.
public struct ATASMARTAttribute: Codable, Sendable, Equatable {
    public var id: Int
    /// Normalized value (vendor scale, usually 100 or 200 = new, lower = worse).
    public var current: Int
    public var worst: Int
    /// Failure threshold (0 = none or not reported).
    public var threshold: Int
    /// Raw value (6 bytes, little endian); its meaning is vendor specific.
    public var raw: UInt64

    /// Below its threshold: the drive considers this attribute failed.
    public var failing: Bool { threshold > 0 && current <= threshold }
}

/// SMART of an ATA / SATA (AHCI) drive: attribute table, thresholds and the drive's own
/// verdict (SMART RETURN STATUS).
public struct ATAHealth: Codable, Sendable, Equatable {
    public var attributes: [ATASMARTAttribute]
    /// The drive reports a threshold exceeded condition (nil: not reported).
    public var thresholdExceeded: Bool?
    /// Product name, for vendor specific attributes (set by the reader).
    public var model: String?

    /// Apple's SanDisk based AHCI SSDs ("APPLE SSD SD0128F" …): 174 / 175 count host reads /
    /// writes in MiB (DriveDx names 175 "Host Writes MiB"), 173 packs erase counts.
    public var isAppleSanDisk: Bool { model?.hasPrefix("APPLE SSD SD") == true }

    /// Apple's AHCI SSDs from Samsung ("APPLE SSD SM…") and SanDisk ("SD…"): 173 runs from 200
    /// (new) down to its threshold 100 (rated endurance used up) and its raw value packs the
    /// NAND erase counts.
    public var isAppleAHCI: Bool { isAppleSanDisk || model?.hasPrefix("APPLE SSD SM") == true }

    /// SSD families whose own wear counter FixStat knows. Each vendor keeps the life in a different
    /// attribute, and some read the same id the other way round (Phison's 231 raw is the life left,
    /// its normalized value the part used), so the life is only read for a known family; for any
    /// other drive FixStat shows the evidence (erase counts, spare, errors) and no percentage.
    /// Families and rules come from bench drives (2026-11): see each case.
    public enum Family: String, Codable, Sendable {
        /// Apple SM… / SD… AHCI: life = 173 normalized − threshold 100 (DriveDx agreed on 9 of 11).
        case appleAHCI
        /// Samsung: 177 Wear_Leveling_Count normalized = life, raw = average P/E cycles
        /// (750 EVO 1 %, 860 PRO 69 %, 850 EVO 84 % / 96 %; DriveDx 1 / 69 / 85).
        case samsung
        /// Western Digital (Blue 3D, Marvell): 230 raw byte 1 = % of life used; 166 / 168 / 173 =
        /// minimum / maximum / average erase count, 169 total bad blocks (WDS500G2B0A: byte 1 = 46, // privacy:allow (model number)
        /// average erase 461, DriveDx 54 %; WDS100T2B0A: 13, 100). // privacy:allow (model number)
        case westernDigital
        /// Phison (Kingston A400 …): 231 raw = life left, normalized = part used; 244 / 245 / 246 =
        /// average / maximum / total erase count (SA400S37960G: raw 97, normalized 3, average 24 of // privacy:allow (model number)
        /// ≈ 1 000, DriveDx 98 %).
        case phison
        /// Silicon Motion: 231 normalized = life left (raw = part used); 206 / 207 / 208 = minimum /
        /// maximum / average erase count (APS-SL3N-240: 91 / 9, average 85).
        case siliconMotion
        /// Kingston UV400 (Marvell): 231 normalized = life left, raw = part used (46 / 54).
        case kingstonMarvell
        /// Crucial / Micron: 202 Percent_Lifetime_Remain normalized = life left.
        case crucial
        /// Intel: 233 Media_Wearout_Indicator normalized = life left.
        case intel

        static func detect(model: String?, has: (Int) -> Bool) -> Family? {
            let name = (model ?? "").uppercased()
            if name.hasPrefix("APPLE SSD SM") || name.hasPrefix("APPLE SSD SD") { return .appleAHCI }
            if name.hasPrefix("SAMSUNG"), has(177) { return .samsung }
            if [230, 232, 233, 234].allSatisfy(has) || (name.hasPrefix("WDC") && has(230)) { return .westernDigital }
            if has(231), [244, 245, 246].allSatisfy(has) { return .phison }
            if [206, 207, 208].allSatisfy(has) { return .siliconMotion }
            if name.hasPrefix("KINGSTON SUV400"), has(231) { return .kingstonMarvell }
            if name.hasPrefix("CRUCIAL") || name.hasPrefix("CT") || name.hasPrefix("MICRON"), has(202) { return .crucial }
            if name.hasPrefix("INTEL"), has(233) { return .intel }
            return nil
        }
    }

    public var family: Family? { Family.detect(model: model) { self.attribute($0) != nil } }

    /// Well-known attribute ids.
    public enum ID {
        public static let reallocated = 5
        public static let powerOnHours = 9
        public static let powerCycles = 12
        public static let unsafeShutdowns = 192
        public static let temperature = 194
        public static let airflowTemperature = 190
        public static let reallocationEvents = 196
        public static let pending = 197
        public static let uncorrectable = 198
        public static let crcErrors = 199
        public static let totalLBAsWritten = 241
        public static let totalLBAsRead = 242
    }

    /// Parses the 512-byte SMART data and threshold structures (ATA/ATAPI-6, 8.54):
    /// 30 attribute entries of 12 bytes from offset 2.
    public static func parse(data: [UInt8], thresholds: [UInt8], exceeded: Int32) -> ATAHealth? {
        guard data.count >= 512 else { return nil }
        var limits: [Int: Int] = [:]
        if thresholds.count >= 512 {
            for entry in 0..<30 {
                let offset = 2 + entry * 12
                if thresholds[offset] != 0 { limits[Int(thresholds[offset])] = Int(thresholds[offset + 1]) }
            }
        }
        var attributes: [ATASMARTAttribute] = []
        for entry in 0..<30 {
            let offset = 2 + entry * 12
            let id = Int(data[offset])
            guard id != 0 else { continue }
            var raw: UInt64 = 0
            for index in (0..<6).reversed() { raw = raw << 8 | UInt64(data[offset + 5 + index]) }
            attributes.append(ATASMARTAttribute(id: id, current: Int(data[offset + 3]), worst: Int(data[offset + 4]),
                                                threshold: limits[id] ?? 0, raw: raw))
        }
        guard !attributes.isEmpty else { return nil }
        return ATAHealth(attributes: attributes, thresholdExceeded: exceeded < 0 ? nil : exceeded == 1)
    }

    public func attribute(_ id: Int) -> ATASMARTAttribute? {
        attributes.first { $0.id == id }
    }

    /// Low 32 bits of a raw value: counters such as power-on hours pack more data above.
    func counter(_ id: Int) -> Double? {
        attribute(id).map { Double($0.raw & 0xFFFF_FFFF) }
    }

    public var powerOnHours: Double? { counter(ID.powerOnHours) }
    public var powerCycles: Double? { counter(ID.powerCycles) }
    /// 192, or 174 "Unexpected power loss count" (Kingston, Crucial, Intel …; on Apple's SanDisk
    /// SSDs 174 counts host reads).
    public var unsafeShutdowns: Double? { counter(ID.unsafeShutdowns) ?? (isAppleSanDisk ? nil : counter(174)) }
    public var reallocatedSectors: Double? { counter(ID.reallocated) }
    public var pendingSectors: Double? { counter(ID.pending) }
    public var uncorrectableSectors: Double? { counter(ID.uncorrectable) }
    public var crcErrors: Double? { counter(ID.crcErrors) }
    /// 194, or 190 "Airflow temperature" (Samsung SATA SSDs report only that one).
    public var temperature: Double? {
        for id in [ID.temperature, ID.airflowTemperature] {
            if let value = attribute(id).map({ Double($0.raw & 0xFF) }), (1...120).contains(value) { return value }
        }
        return nil
    }

    /// What the host write / read counters (241 / 242) count. Most SSDs count LBAs (512 bytes);
    /// some vendors count GiB or 32 MiB, which smartmontools knows per model.
    public enum DataUnit: Equatable, Sendable {
        /// 512-byte LBAs (most drives; the default).
        case lba
        /// GiB: Kingston UV400 (Marvell, bench: 241 = 2601 after 1 240 h, 233 NAND writes 3 303) and
        /// A400 (Phison), SanDisk SSD Plus / Ultra, Silicon Motion controllers (206 – 208 erase counts).
        case gibibytes
        /// 32 MiB: Intel SATA SSDs.
        case mebibytes32
        /// MiB in 174 / 175: Apple's SanDisk SSDs.
        case mebibytesAppleSanDisk
        /// Read as LBAs the total is implausibly small for the power-on time: the drive counts in
        /// a unit FixStat does not know.
        case unknown
    }

    public var dataUnit: DataUnit {
        if isAppleSanDisk { return .mebibytesAppleSanDisk }
        let name = (model ?? "").uppercased()
        if name.hasPrefix("KINGSTON SUV400") || name.hasPrefix("KINGSTON SA400")
            || name.hasPrefix("SANDISK SDSSDA") || name.hasPrefix("SANDISK SDSSDH") {
            return .gibibytes
        }
        if name.hasPrefix("INTEL SSDSC") { return .mebibytes32 }
        // Silicon Motion controllers (many brands: Apacer, Transcend, Kingston A400 / KC600, Lexar …)
        // publish the minimum / maximum / average erase count in 206 / 207 / 208 and count host
        // writes in GiB (APS-SL3N-240, bench: 241 = 6 517 with 85 average erases on 240 GB).
        if [206, 207, 208].allSatisfy({ attribute($0) != nil }) { return .gibibytes }
        // WD (Host_Writes_GiB, WDS500G2B0A: 68 782 = 74 TB beside 233 TLC NAND 233 377 GiB) and Phison // privacy:allow (model number)
        // (Lifetime_Writes_GiB, SA400S37960G: 11 554, as DriveDx reads it). // privacy:allow (model number)
        if family == .westernDigital || family == .phison { return .gibibytes }
        // Less than 10 GB in 100 hours or more: not LBAs.
        if let raw = attribute(ID.totalLBAsWritten)?.raw, raw > 0, Double(raw) * 512 < 10e9,
           let hours = powerOnHours, hours >= 100 {
            return .unknown
        }
        return .lba
    }

    func bytes(_ id: Int) -> Double? {
        guard let raw = attribute(id).map({ Double($0.raw & 0xFFFF_FFFF_FFFF) }) else { return nil }
        switch dataUnit {
        case .lba: return raw * 512
        case .gibibytes: return raw * 1_073_741_824
        case .mebibytes32: return raw * 33_554_432
        case .mebibytesAppleSanDisk, .unknown: return nil
        }
    }

    /// Total data the host wrote: 241 in the drive's unit, or 175 (MiB) on Apple's SanDisk SSDs;
    /// nil when the unit is unknown.
    public var bytesWritten: Double? {
        if dataUnit == .mebibytesAppleSanDisk {
            return attribute(175).map { Double($0.raw & 0xFFFF_FFFF_FFFF) * 1_048_576 }
        }
        return bytes(ID.totalLBAsWritten)
    }

    public var bytesRead: Double? {
        if dataUnit == .mebibytesAppleSanDisk {
            return attribute(174).map { Double($0.raw & 0xFFFF_FFFF_FFFF) * 1_048_576 }
        }
        return bytes(ID.totalLBAsRead)
    }

    /// NAND erase (P/E) cycles per block: the physical wear behind the vendor's life figure.
    public struct EraseCounts: Equatable, Sendable {
        public var average: Int
        public var maximum: Int?
        public var minimum: Int?
    }

    /// Erase counts where the family publishes them: Apple 173 raw (average, maximum, minimum as
    /// 16-bit words), Samsung 177 raw (average), WD 173 / 168 / 166, Phison 244 / 245, Silicon
    /// Motion 208 / 207 / 206.
    public var eraseCounts: EraseCounts? {
        func raw(_ id: Int) -> Int? { attribute(id).map { Int($0.raw & 0xFFFF_FFFF) } }
        switch family {
        case .appleAHCI?:
            guard let a = attribute(173), a.raw > 0 else { return nil }
            let word = { (shift: UInt64) in Int((a.raw >> shift) & 0xFFFF) }
            return EraseCounts(average: word(0), maximum: word(16), minimum: word(32))
        case .samsung?: return raw(177).map { EraseCounts(average: $0) }
        case .westernDigital?: return raw(173).map { EraseCounts(average: $0, maximum: raw(168), minimum: raw(166)) }
        case .phison?: return raw(244).map { EraseCounts(average: $0, maximum: raw(245)) }
        case .siliconMotion?: return raw(208).map { EraseCounts(average: $0, maximum: raw(207), minimum: raw(206)) }
        default: return nil
        }
    }

    /// Remaining life in % from the family's own wear counter, and that attribute's id; nil for a
    /// drive whose family FixStat does not know (no guessing from attribute ids: WD's 169 counts bad
    /// blocks and read "100 %", Phison's 231 normalized is the part used and read "3 %"). A vendor
    /// estimate of the rated endurance left, like NVMe's percentage used.
    public var lifeLeft: (percent: Int, attribute: Int)? {
        func normalized(_ id: Int) -> (Int, Int)? {
            attribute(id).flatMap { (0...100).contains($0.current) ? ($0.current, id) : nil }
        }
        switch family {
        case .appleAHCI?:
            // 173 runs from 200 down to its threshold 100. DriveDx showed 97.5 % on two SD0128F with
            // 563 and 1 720 average erase cycles, where 173 gives 78 / 39 %.
            guard let a = attribute(173), a.threshold == 100, (100...200).contains(a.current) else { return nil }
            return (a.current - 100, 173)
        case .samsung?: return normalized(177)
        case .westernDigital?:
            guard let a = attribute(230) else { return nil }
            let used = Int((a.raw >> 8) & 0xFF)
            return used <= 100 ? (100 - used, 230) : nil
        case .phison?:
            guard let a = attribute(231), a.raw <= 100 else { return nil }
            return (Int(a.raw), 231)
        case .siliconMotion?, .kingstonMarvell?: return normalized(231)
        case .crucial?: return normalized(202)
        case .intel?: return normalized(233)
        case nil: return nil
        }
    }

    /// Attributes below their failure threshold.
    public var failingAttributes: [ATASMARTAttribute] { attributes.filter(\.failing) }
}

/// A SMART capable internal ATA drive (AHCI SSD, SATA SSD or hard disk), or an external drive
/// (USB / Thunderbolt), SMART capable or not.
public struct ATADrive: Codable, Sendable, Equatable {
    public var model: String?
    public var firmware: String?
    public var serial: String?
    /// "Solid State" or "Rotational".
    public var medium: String?
    /// "SATA", "PCI-Express" …
    public var interconnect: String?
    /// Bytes.
    public var capacity: Double?
    public var health: ATAHealth?
    /// Why SMART could not be read (IOKit return code), for the technician and bug reports.
    public var smartError: String?
    /// Read / write errors and retries since startup (no SMART needed).
    public var io: DiskIOStatistics?

    /// External drives: the USB device the drive sits on (an enclosure's bridge chip, a stick).
    public var usb: USBDeviceInfo?
    /// External drives: "disk4".
    public var bsdName: String?
    /// External drives: the drive offers SMART ("SMART Capable"; false: a USB bridge that does not
    /// pass SMART through, a memory stick).
    public var smartCapable: Bool?
    /// External drives: an NVMe drive (Thunderbolt enclosure, USB4, or behind a USB–NVMe bridge
    /// that shows it as one).
    public var nvme: Bool?
    /// External NVMe drives: SMART / health log (NVMeSMARTLib, like the internal SSD).
    public var nvmeHealth: NVMeHealth?
    /// External drives: behind a Thunderbolt PCIe tunnel.
    public var thunderbolt: Bool?

    public var isSolidState: Bool { medium?.localizedCaseInsensitiveContains("solid") ?? true }

    /// Every internal SMART capable ATA block device.
    public static func readAll(includeSerial: Bool = false) -> [ATADrive] {
        read(external: false, includeSerial: includeSerial)
    }

    /// Every external drive (USB, Thunderbolt, FireWire) with media; SMART read where the drive
    /// (its bridge) offers it. Disk images and other virtual devices are left out.
    public static func readExternal(includeSerial: Bool = false) -> [ATADrive] {
        var drives = read(external: true, includeSerial: includeSerial)
        if UserDefaults.standard.bool(forKey: "FixStatSampleExternalDrive") { drives += sampleExternal() }
        return drives
    }

    static func read(external: Bool, includeSerial: Bool) -> [ATADrive] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(ioMainPort, IOServiceMatching("IOBlockStorageDevice"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var drives: [ATADrive] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let properties = Registry.properties(of: service) else { continue }
            let smartCapable = (properties["SMART Capable"] as? NSNumber)?.boolValue == true
            let device = properties.dict("Device Characteristics") ?? [:]
            let protocolInfo = properties.dict("Protocol Characteristics") ?? [:]
            var drive = ATADrive()
            if external {
                // "File" / "Virtual": disk images; an empty card reader has no media.
                guard StorageLocation.isExternal(service), protocolInfo.string("Physical Interconnect") != "Virtual Interface",
                      let size = mediaSize(below: service), size > 0 else { continue }
                drive.smartCapable = smartCapable
                let nvmeSMART = (properties["NVMe SMART Capable"] as? NSNumber)?.boolValue == true
                drive.nvme = nvmeSMART || IOObjectConformsTo(service, "IONVMeBlockStorageDevice") != 0 ? true : nil
                drive.thunderbolt = StorageLocation.isThunderbolt(service) ? true : nil
                drive.bsdName = wholeDiskName(below: service)
                drive.usb = USBVolumes.usbDevice(above: service)
                if nvmeSMART {
                    drive.smartCapable = true
                    drive.nvmeHealth = SSDInfo.readHealth(of: service)
                    if drive.nvmeHealth == nil { drive.smartError = "NVMe SMART read failed" }
                }
            } else {
                guard smartCapable, StorageLocation.isInternal(service) else { continue }
            }
            drive.model = device.string("Product Name")?.trimmingCharacters(in: .whitespaces)
            if external, let vendor = device.string("Vendor Name")?.trimmingCharacters(in: .whitespaces), !vendor.isEmpty,
               let model = drive.model, !model.localizedCaseInsensitiveContains(vendor) {
                // USB / SCSI drives split the name: "Samsung" + "SSD 870 EVO 500G".
                drive.model = vendor + " " + model
            }
            drive.firmware = device.string("Product Revision Level")?.trimmingCharacters(in: .whitespaces)
            if let serial = device.string("Serial Number")?.trimmingCharacters(in: .whitespaces), !serial.isEmpty {
                drive.serial = includeSerial ? serial : Privacy.mask(serial)
            }
            drive.medium = device.string("Medium Type")
            drive.interconnect = protocolInfo.string("Physical Interconnect")
            drive.capacity = mediaSize(below: service)
            drive.io = DiskIOStatistics.below(service)
            guard smartCapable, drive.nvme != true else {
                drives.append(drive)
                continue
            }
            var data = [UInt8](repeating: 0, count: 512)
            var thresholds = [UInt8](repeating: 0, count: 512)
            var exceeded: Int32 = -1
            var steps = [kern_return_t](repeating: FSATAStepNotRun, count: Int(FSATAStepCount))
            let result = FSATAReadSMART(service, &data, &thresholds, &exceeded, &steps)
            if result == KERN_SUCCESS {
                drive.health = ATAHealth.parse(data: data, thresholds: thresholds, exceeded: exceeded)
                drive.health?.model = drive.model
                if drive.health == nil { drive.smartError = "empty attribute table" }
            } else {
                drive.smartError = Self.describe(steps: steps)
            }
            drives.append(drive)
        }
        return drives
    }

    /// "plugin ok · interface ok · identify ok · read 0xe00002ca · retry 0xe00002ca · parent plugin
    /// 0xe00002c7": every attempt of `FSATAReadSMART`, for the technician and bug reports.
    static func describe(steps: [kern_return_t]) -> String {
        let names = ["plugin", "interface", "identify", "read", "retry", "parent plugin", "parent read"]
        return zip(names, steps).compactMap { name, code in
            guard code != FSATAStepNotRun else { return nil }
            return name + " " + (code == KERN_SUCCESS ? "ok" : String(format: "0x%08x", UInt32(bitPattern: code)))
        }.joined(separator: " · ")
    }

    /// BSD name of the whole-disk IOMedia below a block storage device ("disk4").
    static func wholeDiskName(below service: io_service_t) -> String? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively)) as? String
    }

    /// `-FixStatSampleExternalDrive YES`: a made-up SATA SSD in a USB enclosure (SMART through the
    /// bridge, a few CRC errors), an NVMe SSD behind a USB bridge that does not pass SMART on and a
    /// worn NVMe SSD in a Thunderbolt enclosure.
    static func sampleExternal() -> [ATADrive] {
        func a(_ id: Int, _ current: Int, _ raw: UInt64) -> ATASMARTAttribute {
            ATASMARTAttribute(id: id, current: current, worst: current, threshold: 0, raw: raw)
        }
        var sata = ATADrive(model: "Samsung SSD 860 EVO 250GB", firmware: "RVT04B6Q", serial: nil, medium: "Solid State",
                            interconnect: "USB", capacity: 250_059_350_016,
                            health: ATAHealth(attributes: [a(5, 100, 0), a(9, 97, 14_211), a(12, 99, 1_204), a(177, 91, 108),
                                                           a(187, 100, 0), a(190, 66, 34), a(199, 99, 14),
                                                           a(241, 99, 61_349_521_408)],
                                              thresholdExceeded: false, model: "Samsung SSD 860 EVO 250GB"),
                            io: DiskIOStatistics(readErrors: 0, writeErrors: 0, readRetries: 0, writeRetries: 0,
                                                 bytesRead: 2_400_000_000, bytesWritten: 310_000_000))
        sata.usb = USBDeviceInfo(name: "USB 3.0 SATA Adapter", vendorID: 0x152D, productID: 0x0578, speed: 3, portNumber: 1)
        sata.bsdName = "disk98"
        sata.smartCapable = true
        var nvme = ATADrive(model: "WD_BLACK SN770 1TB", firmware: "1.00", serial: nil, medium: "Solid State",
                            interconnect: "USB", capacity: 1_000_204_886_016, health: nil, smartError: nil,
                            io: DiskIOStatistics(readErrors: 0, writeErrors: 0, readRetries: 0, writeRetries: 0,
                                                 bytesRead: 900_000_000, bytesWritten: 0))
        nvme.usb = USBDeviceInfo(name: "RTL9210B-CG", vendorID: 0x0BDA, productID: 0x9210, speed: 4, portNumber: 2)
        nvme.bsdName = "disk99"
        nvme.smartCapable = false
        var thunderbolt = ATADrive(model: "Samsung SSD 970 EVO Plus 2TB", firmware: "2B2QEXM7", serial: nil,
                                   medium: "Solid State", interconnect: "PCI-Express", capacity: 2_000_398_934_016,
                                   io: DiskIOStatistics(readErrors: 0, writeErrors: 0, readRetries: 0, writeRetries: 0,
                                                        bytesRead: 5_100_000_000, bytesWritten: 1_200_000_000))
        thunderbolt.nvmeHealth = NVMeHealth(criticalWarning: 0, temperature: 47, availableSpare: 100, availableSpareThreshold: 10,
                                            percentageUsed: 84, bytesRead: 410e12, bytesWritten: 1_020e12, powerCycles: 2_310,
                                            powerOnHours: 21_480, unsafeShutdowns: 188, mediaErrors: 0, errorLogEntries: 41)
        thunderbolt.bsdName = "disk97"
        thunderbolt.smartCapable = true
        thunderbolt.nvme = true
        thunderbolt.thunderbolt = true
        return [sata, nvme, thunderbolt]
    }

    /// Size of the whole-disk IOMedia below a block storage device.
    static func mediaSize(below service: io_service_t) -> Double? {
        guard let size = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Size" as CFString, kCFAllocatorDefault,
                                                         IOOptionBits(kIORegistryIterateRecursively)) as? NSNumber
        else { return nil }
        return size.doubleValue
    }
}

/// Space on the internal SSD (the APFS container is shared by its volumes; "used" is what
/// is not available, as Finder shows it): the startup volume, or `InternalStorage.space()`.
public struct VolumeSpace: Codable, Sendable, Equatable {
    public var total: Double
    public var available: Double
    /// The Mac was started from another disk: this is the internal SSD, not the startup volume.
    public var startedFromOtherDisk: Bool?
    public var used: Double { max(0, total - available) }

    public init(total: Double, available: Double, startedFromOtherDisk: Bool? = nil) {
        self.total = total
        self.available = available
        self.startedFromOtherDisk = startedFromOtherDisk
    }

    public static func startup() -> VolumeSpace? {
        of(URL(fileURLWithPath: "/"))
    }

    /// Space of the volume (its APFS container) at `url`.
    public static func of(_ url: URL) -> VolumeSpace? {
        var keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        if #available(macOS 10.13, *) { keys.insert(.volumeAvailableCapacityForImportantUsageKey) }
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else { return nil }
        // "Important usage" counts purgeable space as available, like Finder.
        let available = values.volumeAvailableCapacityForImportantUsage.map(Double.init)
            ?? values.volumeAvailableCapacity.map(Double.init) ?? 0
        return VolumeSpace(total: Double(total), available: available)
    }
}
