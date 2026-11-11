import AVFoundation
import Foundation
import LocalAuthentication
import MacSensors

/// Parts that stop working after a board or part swap until Apple pairs them, or that go missing
/// when a cable is not seated: Touch ID, True Tone, the camera, the ambient light sensor and the lid
/// angle sensor, each compared with what this model should have. Nothing is prompted: Touch ID is
/// asked only whether it could be used (LocalAuthentication), True Tone through CoreBrightness.
public struct PairingTraces: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Present and working.
        case working
        /// Touch ID works but no fingerprint is enrolled, so the sensor itself was not tried.
        case notEnrolled
        /// Touch ID locked after failed attempts (the sensor answered).
        case lockedOut
        /// Expected on this model but not there or not usable.
        case missing
        /// True Tone: the Mac supports it but macOS does not offer it (an unpaired display).
        case unavailable
        /// Not on this model and not found.
        case notExpected
    }

    public struct Item: Equatable, Sendable {
        /// "touchID", "trueTone", "camera", "lightSensor", "lidAngle"
        public let id: String
        public let status: Status
        public var problem: Bool { status == .missing || status == .unavailable }
    }

    public let items: [Item]

    public var problems: [Item] { items.filter(\.problem) }

    public static func read(system: SystemInfo = .current(), profile: HardwareProfile = .current()) -> PairingTraces {
        let notebook = profile.isNotebook
        var items: [Item] = []
        items.append(Item(id: "touchID", status: touchID(expected: touchIDExpected(model: system.model, appleSilicon: system.isAppleSilicon,
                                                                                    notebook: notebook))))
        items.append(Item(id: "trueTone", status: trueTone(expected: trueToneExpected(model: system.model,
                                                                                       appleSilicon: system.isAppleSilicon,
                                                                                       builtInDisplay: profile.hasBuiltInDisplay))))
        let camera = builtInCamera()
        items.append(Item(id: "camera", status: camera ? .working : profile.hasBuiltInCamera ? .missing : .notExpected))
        let light = AmbientLightSensor.read() != nil
        items.append(Item(id: "lightSensor", status: light ? .working : profile.hasAmbientLightSensor ? .missing : .notExpected))
        let lidExpected = LidAngleSensor.expected(model: system.model, notebook: notebook)
        let lid = LidAngleSensor.isPresent
        items.append(Item(id: "lidAngle", status: lid ? .working : lidExpected ? .missing : .notExpected))
        return PairingTraces(items: items.filter { $0.status != .notExpected })
    }

    /// A camera with the built-in transport ('bltn'): an external webcam or an iPhone (Continuity
    /// Camera) does not count.
    static func builtInCamera() -> Bool {
        AVCaptureDevice.devices(for: .video).contains { $0.transportType == 0x626C_746E }
    }

    // MARK: Touch ID

    /// Every Apple Silicon MacBook; Intel: MacBook Air 2018 – 2020 and the MacBook Pros with a
    /// Touch Bar (the power key holds the sensor).
    public static func touchIDExpected(model: String, appleSilicon: Bool, notebook: Bool) -> Bool {
        guard notebook else { return false }
        if appleSilicon { return true }
        let intel: Set<String> = ["MacBookAir8,1", "MacBookAir8,2", "MacBookAir9,1",
                                  "MacBookPro13,2", "MacBookPro13,3", "MacBookPro14,2", "MacBookPro14,3",
                                  "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3", "MacBookPro15,4",
                                  "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4"]
        return intel.contains(model)
    }

    /// Asks LocalAuthentication whether Touch ID could be used, without a prompt. On a desktop a
    /// Magic Keyboard with Touch ID counts too.
    static func touchID(expected: Bool) -> Status {
        let context = LAContext()
        var error: NSError?
        let usable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        var hasSensor = usable
        if #available(macOS 10.13.2, *) { hasSensor = context.biometryType == .touchID }
        if usable { return .working }
        switch error?.code {
        case LAError.Code.biometryNotEnrolled.rawValue where hasSensor || expected: return .notEnrolled
        case LAError.Code.biometryLockout.rawValue: return .lockedOut
        default: return expected ? .missing : .notExpected
        }
    }

    // MARK: True Tone

    /// Apple Silicon MacBooks and iMacs; Intel: MacBook Pro 2018 and later, MacBook Air 2019 / 2020,
    /// iMac 2020.
    public static func trueToneExpected(model: String, appleSilicon: Bool, builtInDisplay: Bool) -> Bool {
        guard builtInDisplay else { return false }
        if appleSilicon { return true }
        return model.hasPrefix("MacBookPro15,") || model.hasPrefix("MacBookPro16,")
            || ["MacBookAir8,2", "MacBookAir9,1", "iMac20,1", "iMac20,2"].contains(model)
    }

    /// CoreBrightness' True Tone client (private): `supported` by the Mac, `available` when the
    /// display and the light sensor allow it (an unpaired replacement display does not).
    static func trueTone(expected: Bool) -> Status {
        guard let state = trueToneState() else { return expected ? .missing : .notExpected }
        if state.available { return .working }
        if state.supported || expected { return .unavailable }
        return .notExpected
    }

    static func trueToneState() -> (supported: Bool, available: Bool)? {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("CBTrueToneClient") as? NSObject.Type else { return nil }
        let client = type.init()
        func flag(_ name: String) -> Bool? {
            let selector = NSSelectorFromString(name)
            guard client.responds(to: selector), let method = client.method(for: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: Getter.self)(client, selector)
        }
        guard let supported = flag("supported"), let available = flag("available") else { return nil }
        return (supported, available)
    }
}
