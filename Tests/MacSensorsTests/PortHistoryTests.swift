import FixStatCore
import Testing
@testable import MacSensors

@Suite struct PortHistoryTests {
    static func port(_ number: Int, speed: Int?) -> PortStatus {
        PortStatus(type: "USB-A", number: number, connected: speed != nil, activeTransports: [], supportedTransports: [],
                   powerIn: nil, overcurrentCount: nil, connectionCount: nil, enumerationFailures: 0,
                   devices: speed.map { [USBDeviceInfo(name: "Ugreen Storage Device", vendorID: 5964, productID: 4435,
                                                       speed: $0, portNumber: nil)] } ?? [])
    }

    @Test func usb3DeviceAtUSB2SpeedFlagsThePort() {
        // Air 2014: the same disk at 5 Gb/s in USB-A 2, at 480 Mb/s in USB-A 1.
        var history = PortHistory()
        _ = history.update([Self.port(1, speed: nil), Self.port(2, speed: 3)])
        _ = history.update([Self.port(1, speed: 2), Self.port(2, speed: nil)])
        let slow = history.slowLane(Self.port(1, speed: nil))
        #expect(slow?.here == 480)
        #expect(slow?.elsewhere == 5_000)
        #expect(history.slowLane(Self.port(2, speed: nil)) == nil)
        #expect(history.allDataTested([Self.port(1, speed: nil), Self.port(2, speed: nil)]))
        #expect(!history.passed([Self.port(1, speed: nil), Self.port(2, speed: nil)]))
    }

    @Test func usb2OnlyDeviceIsNotAFault() {
        var history = PortHistory()
        _ = history.update([Self.port(1, speed: 2), Self.port(2, speed: 2)])
        #expect(history.slowLane(Self.port(1, speed: nil)) == nil)
    }
}

/// macOS 27: USB devices are tied to USB-C ports through the ports' USB transports.
@Suite struct TransportPortTests {
    @Test func matchesTheOnlyPortWithThatDevice() {
        let transports = [(port: 2, vendor: 0x174C, product: 0x1153), (port: 2, vendor: 0x174C, product: 0x1153)]
        #expect(PortReader.port(attached: (0x174C, 0x1153), transports: transports) == 2)
        #expect(PortReader.port(attached: (0x05AC, 0x1234), transports: transports) == nil)
    }

    @Test func twoIdenticalDevicesGetNoPort() {
        let transports = [(port: 1, vendor: 0x0781, product: 0x5581), (port: 2, vendor: 0x0781, product: 0x5581)]
        #expect(PortReader.port(attached: (0x0781, 0x5581), transports: transports) == nil)
    }
}

/// Charging per port: the same adapter compared between ports.
@Suite struct ChargingPerPortTests {
    static func port(_ number: Int, charging: Bool, faults: Int = 0) -> PortStatus {
        PortStatus(type: "USB-C", number: number, connected: charging, activeTransports: charging ? ["CC"] : [],
                   supportedTransports: ["CC", "USB2", "USB3"], powerIn: charging, overcurrentCount: 0, connectionCount: 1,
                   enumerationFailures: 0,
                   controller: PortControllerCounters(charging: charging, maxPowerWatts: nil, shortDetect: 0, hardReset: faults,
                                                      inputFETFailures: 0, i2cErrors: 0),
                   devices: [])
    }

    static func battery(volts: Int) -> BatteryInfo {
        var b = BatteryInfo()
        b.externalConnected = true
        b.amperage = 2000
        var pd = PowerDeliveryInfo(sourceCapabilities: [], contract: nil, capabilityMismatch: nil,
                                   attachCount: nil, detachCount: nil, hardResetCount: nil, portIndex: 0)
        pd.adapterProfiles = [5000, 9000, 15000, 20000].map {
            PowerDataObject(kind: .fixed, maxVoltage: $0, minVoltage: nil, maxCurrent: 3000, maxPower: nil, raw: 0)
        }
        pd.adapterSelectedIndex = [5000, 9000, 15000, 20000].firstIndex(of: volts)
        b.powerDelivery = pd
        var adapter = AdapterInfo()
        adapter.name = "96W USB-C Power Adapter"
        adapter.ratedWatts = 96
        b.adapter = adapter
        return b
    }

    @Test func aPortThatChargesClearlyWorseIsFlagged() {
        var history = PortHistory()
        _ = history.update([Self.port(1, charging: true), Self.port(2, charging: false)], battery: Self.battery(volts: 20000))
        _ = history.update([Self.port(1, charging: false), Self.port(2, charging: true)], battery: Self.battery(volts: 9000))
        let ports = [Self.port(1, charging: false), Self.port(2, charging: false)]
        #expect(history.charging["USB-C@1"]?.contractWatts == 60)
        #expect(history.charging["USB-C@2"]?.contractWatts == 27)
        #expect(history.chargingFindings(ports).count == 1)
        #expect(!history.passed(ports))
    }

    @Test func fiveVoltsOnlyIsFlagged() {
        var history = PortHistory()
        _ = history.update([Self.port(1, charging: true)], battery: Self.battery(volts: 5000))
        #expect(history.chargingFindings([Self.port(1, charging: false)]).count == 1)
    }

    @Test func faultsWhileChargingAreCounted() {
        var history = PortHistory()
        _ = history.update([Self.port(1, charging: false)], battery: nil)
        _ = history.update([Self.port(1, charging: true, faults: 2)], battery: Self.battery(volts: 20000))
        #expect(history.charging["USB-C@1"]?.faults == 2)
        #expect(history.chargingFindings([Self.port(1, charging: false)]).count == 1)
    }

    @Test func equalPortsPass() {
        var history = PortHistory()
        _ = history.update([Self.port(1, charging: true), Self.port(2, charging: false)], battery: Self.battery(volts: 20000))
        _ = history.update([Self.port(1, charging: false), Self.port(2, charging: true)], battery: Self.battery(volts: 20000))
        #expect(history.chargingFindings([Self.port(1, charging: false), Self.port(2, charging: false)]).isEmpty)
    }
}
