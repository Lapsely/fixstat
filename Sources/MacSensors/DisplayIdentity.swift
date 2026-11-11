import Foundation
import IOKit

/// What the built-in display says about itself: the panel's own identity string on Apple Silicon
/// (`Panel_ID` of the internal `AppleCLCD2`, read by the display controller from the panel's memory),
/// the panel's EDID on Intel (`AppleBacklightDisplay`), Apple's product id and the timing
/// controller (TCON) chip from the device tree. No root; nothing is written.
///
/// Meant as evidence for display swaps: an aftermarket LCD panel is not expected to carry Apple's
/// panel identity. What each `Panel_ID` field means is still being learned from bench records.
public struct DisplayIdentity: Equatable {
    /// The panel identity string, split at "+" (Apple Silicon). Field 0 is the panel serial.
    public struct PanelID: Equatable {
        public var fields: [String]

        public init(_ raw: String) {
            fields = raw.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        }

        /// The panel's serial number (17 characters on the M1 Air).
        public var serial: String? { fields.first.flatMap { $0.isEmpty ? nil : $0 } }
        /// Factory / maker code: the first three characters of the serial.
        public var makerCode: String? { serial.map { String($0.prefix(3)) } }
        /// The panel says it is a production part.
        public var isProduction: Bool { fields.contains("PROD") }

        /// Every field with identifying characters masked: the serial keeps its first 7 characters
        /// (maker and date code), fields with little information (zeros, "PROD", a revision such as
        /// "00000000DT04D3") are kept, any other field keeps its first 4 characters. Each field also
        /// shows its shape (A = letter, 9 = digit), so layouts can be compared between Macs.
        public var maskedFields: [String] {
            fields.enumerated().map { index, field in
                let kept: String
                if index == 0 {
                    kept = Self.keep(field, 7)
                } else if field.replacingOccurrences(of: "0", with: "").count <= 6 {
                    kept = field
                } else {
                    kept = Self.keep(field, 4)
                }
                return "\(index): \(kept) [\(field.count) \(Self.shape(field))]"
            }
        }

        static func keep(_ text: String, _ count: Int) -> String {
            text.count <= count ? text : String(text.prefix(count)) + String(repeating: "*", count: text.count - count)
        }

        static func shape(_ text: String) -> String {
            String(text.map { $0.isNumber ? "9" : ($0.isLetter ? "A" : $0) })
        }
    }

    /// The parts of an EDID that do not identify the unit (bytes 12–15 and 0xFF descriptors are the
    /// serial and are left out).
    public struct EDID: Equatable {
        /// PNP id ("APP" = Apple).
        public var vendor: String
        public var product: Int
        /// Week of manufacture (0 = not given, 255 = the year is the model year).
        public var week: Int
        public var year: Int
        /// Display name descriptor (0xFC), e.g. "Color LCD".
        public var name: String?
        /// Unspecified text descriptors (0xFE): panel makers put the panel part number here.
        public var texts: [String]

        public init?(_ data: Data) {
            let b = [UInt8](data)
            guard b.count >= 128, b[0] == 0x00, b[1] == 0xFF, b[7] == 0x00 else { return nil }
            let id = Int(b[8]) << 8 | Int(b[9])
            let letters = [(id >> 10) & 0x1F, (id >> 5) & 0x1F, id & 0x1F].map { value -> Character in
                (1...26).contains(value) ? Character(UnicodeScalar(UInt8(64 + value))) : "?"
            }
            vendor = String(letters)
            product = Int(b[10]) | Int(b[11]) << 8
            week = Int(b[16])
            year = 1990 + Int(b[17])
            var name: String?
            var texts: [String] = []
            for start in stride(from: 54, through: 108, by: 18) where b[start] == 0 && b[start + 1] == 0 {
                let text = Self.text(b[(start + 5)..<(start + 18)])
                switch b[start + 3] {
                case 0xFC: name = text
                case 0xFE: if !text.isEmpty { texts.append(text) }
                default: break
                }
            }
            self.name = name
            self.texts = texts
        }

        static func text(_ bytes: ArraySlice<UInt8>) -> String {
            let line = bytes.prefix { $0 != 0x0A && $0 != 0 }
            return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }

    /// The display's timing controller from the device tree (Apple Silicon notebooks).
    public struct TCON: Equatable {
        /// Device tree name, e.g. "dp855" (Parade DP855).
        public var chip: String
        /// Firmware version word (little endian), if published.
        public var firmware: UInt32?
        /// Driver class, e.g. "AppleParadeDP855TCON".
        public var driver: String?
    }

    /// The Mac has a built-in display that macOS drives (false on desktops without one, or with the
    /// lid closed on some Intel Macs).
    public var hasInternalDisplay: Bool
    public var panel: PanelID?
    /// Apple's display product id ("ProductID" of ProductAttributes, or the EDID product).
    public var productID: Int?
    /// IEEE OUI of the manufacturer ("00-10-fa" = Apple), Apple Silicon.
    public var manufacturerOUI: String?
    public var edid: EDID?
    public var tcon: TCON?

    public init(hasInternalDisplay: Bool = false, panel: PanelID? = nil, productID: Int? = nil,
                manufacturerOUI: String? = nil, edid: EDID? = nil, tcon: TCON? = nil) {
        self.hasInternalDisplay = hasInternalDisplay
        self.panel = panel
        self.productID = productID
        self.manufacturerOUI = manufacturerOUI
        self.edid = edid
        self.tcon = tcon
    }

    /// Reads the built-in display's identity.
    public static func read() -> DisplayIdentity {
        var identity = DisplayIdentity()
        for props in internalCLCDProperties() {
            identity.hasInternalDisplay = true
            if identity.panel == nil, let raw = props.string("Panel_ID"), !raw.isEmpty {
                identity.panel = PanelID(raw)
            }
            if let product = props.dict("DisplayAttributes")?.dict("ProductAttributes") {
                identity.productID = identity.productID ?? product.int("ProductID")
                identity.manufacturerOUI = identity.manufacturerOUI ?? product.string("ManufacturerID")
            }
        }
        if let props = Registry.properties(ofClass: "AppleBacklightDisplay") {
            identity.hasInternalDisplay = true
            if let data = props["IODisplayEDID"] as? Data { identity.edid = EDID(data) }
            identity.productID = identity.productID ?? props.int("DisplayProductID")
        }
        identity.tcon = readTCON()
        return identity
    }

    /// Properties of every `AppleCLCD2` that drives the built-in display (below "disp0"; external
    /// displays hang below "dispext…").
    static func internalCLCDProperties() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(ioMainPort, IOServiceMatching("AppleCLCD2"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            if ancestorNames(of: service).contains(where: { $0.hasPrefix("disp0") }),
               let props = Registry.properties(of: service) {
                result.append(props)
            }
            IOObjectRelease(service)
        }
        return result
    }

    static func ancestorNames(of entry: io_registry_entry_t) -> [String] {
        var names: [String] = []
        var current = entry
        IOObjectRetain(current)
        for _ in 0..<12 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
            var name = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetName(current, &name) == KERN_SUCCESS { names.append(Registry.string(from: name)) }
        }
        IOObjectRelease(current)
        return names
    }

    /// The first device tree node with device_type "tcon".
    static func readTCON() -> TCON? {
        let root = IORegistryGetRootEntry(ioMainPort)
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIODeviceTreePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            guard let type = dataString(entry, "device_type"), type == "tcon" else { continue }
            let chip = dataString(entry, "name") ?? "?"
            var firmware: UInt32?
            if let data = property(entry, "firmware-ver") as? Data, data.count >= 4 {
                firmware = data.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            }
            return TCON(chip: chip, firmware: firmware, driver: driverClass(below: entry))
        }
        return nil
    }

    /// The class of the driver attached to a device tree node (its first child in the service plane).
    static func driverClass(below entry: io_registry_entry_t) -> String? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let child = IOIteratorNext(iterator)
        guard child != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(child) }
        return Registry.className(of: child)
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func dataString(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let data = property(entry, key) as? Data else { return nil }
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// A product id made of printable ASCII bytes (the M1 Air reads "92014A"), most significant first.
    static func ascii(_ value: Int) -> String? {
        var bytes: [UInt8] = []
        var v = UInt64(bitPattern: Int64(value))
        while v != 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        guard bytes.count >= 3, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Plain-text lines for dumps and `sensordump` (identifying characters masked).
    public var maskedLines: [String] {
        var lines = ["internal display: \(hasInternalDisplay ? "yes" : "no")"]
        if let panel {
            lines.append("panel id: \(panel.fields.count) fields, production: \(panel.isProduction ? "yes" : "no")")
            lines += panel.maskedFields.map { "  field " + $0 }
        } else if hasInternalDisplay {
            lines.append("panel id: none")
        }
        if let productID {
            var line = "product id: " + String(format: "0x%llx (%lld)", Int64(productID), Int64(productID))
            if let text = Self.ascii(productID) { line += " ascii \"\(text)\"" }
            lines.append(line)
        }
        if let manufacturerOUI { lines.append("manufacturer OUI: \(manufacturerOUI)") }
        if let edid {
            lines.append("EDID: vendor \(edid.vendor), product " + String(format: "0x%04x", edid.product)
                + ", week \(edid.week), year \(edid.year), name \(edid.name ?? "-")")
            lines += edid.texts.map { "  EDID text: \($0)" }
        }
        if let tcon {
            lines.append("TCON: \(tcon.chip), driver \(tcon.driver ?? "-"), firmware "
                + (tcon.firmware.map { String(format: "0x%08x", $0) } ?? "-"))
        } else {
            lines.append("TCON: none in the device tree")
        }
        return lines
    }
}
