import Foundation
import Testing
@testable import MacSensors

@Suite struct DisplayIdentityTests {
    // A made-up panel id with the M1 Air's layout (no real serial).
    let raw = "ABC1234XYZWQ5RT9K+00000000DT04D3+PROD+B000000000000+00000000000000000000000000" // privacy:allow (made up)
        + "+PA01M2345P6789012Y+1234AB5C6D789012EFGHIJ34567K89012+S123456789S123456789S123456789S1234567" // privacy:allow

    @Test func panelFieldsAndMasking() {
        let panel = DisplayIdentity.PanelID(raw)
        #expect(panel.fields.count == 8)
        #expect(panel.isProduction)
        #expect(panel.makerCode == "ABC")
        let masked = panel.maskedFields
        #expect(masked[0] == "0: ABC1234********** [17 AAA9999AAAAA9AA9A]")
        #expect(masked[1].hasPrefix("1: 00000000DT04D3 "))
        #expect(masked[2].hasPrefix("2: PROD "))
        #expect(masked[5].hasPrefix("5: PA01**************"))
        // No field keeps more than its first 7 characters of anything identifying.
        #expect(!masked.joined().contains("WQ5RT9K"))
        #expect(!masked.joined().contains("123456789S"))
    }

    @Test func emptyPanelID() {
        let panel = DisplayIdentity.PanelID("")
        #expect(panel.serial == nil)
        #expect(!panel.isProduction)
    }

    @Test func edidWithoutSerial() {
        var b = [UInt8](repeating: 0, count: 128)
        b[0] = 0; for i in 1...6 { b[i] = 0xFF }; b[7] = 0
        // "APP" = 0x0610, product 0xa045 (little endian), serial bytes 12–15 set.
        b[8] = 0x06; b[9] = 0x10; b[10] = 0x45; b[11] = 0xA0
        b[12] = 1; b[13] = 2; b[14] = 3; b[15] = 4
        b[16] = 12; b[17] = 25
        func descriptor(_ start: Int, _ type: UInt8, _ text: String) {
            b[start + 3] = type
            let bytes = Array(text.utf8) + [0x0A]
            for (i, c) in bytes.prefix(13).enumerated() { b[start + 5 + i] = c }
        }
        descriptor(54, 0xFC, "Color LCD")
        descriptor(72, 0xFE, "LP133WQ1-SJE1")
        descriptor(90, 0xFF, "SERIAL123")
        let edid = DisplayIdentity.EDID(Data(b))
        #expect(edid?.vendor == "APP")
        #expect(edid?.product == 0xA045)
        #expect(edid?.week == 12)
        #expect(edid?.year == 2015)
        #expect(edid?.name == "Color LCD")
        #expect(edid?.texts == ["LP133WQ1-SJE1"])
        #expect(DisplayIdentity.EDID(Data(repeating: 0, count: 128)) == nil)
    }

    @Test func asciiProductID() {
        #expect(DisplayIdentity.ascii(0x393230313441) == "92014A")
        #expect(DisplayIdentity.ascii(0xA045) == nil)
    }
}
