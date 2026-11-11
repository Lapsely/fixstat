import Foundation
import Testing
@testable import FixStatCore
import MacSensors

@Suite struct PairingTracesTests {
    @Test func touchIDModels() {
        #expect(PairingTraces.touchIDExpected(model: "MacBookAir10,1", appleSilicon: true, notebook: true))
        #expect(PairingTraces.touchIDExpected(model: "MacBookPro15,1", appleSilicon: false, notebook: true))
        #expect(!PairingTraces.touchIDExpected(model: "MacBookAir6,1", appleSilicon: false, notebook: true))
        #expect(!PairingTraces.touchIDExpected(model: "Mac14,3", appleSilicon: true, notebook: false))
    }

    @Test func trueToneModels() {
        #expect(PairingTraces.trueToneExpected(model: "Mac16,12", appleSilicon: true, builtInDisplay: true))
        #expect(PairingTraces.trueToneExpected(model: "MacBookAir8,2", appleSilicon: false, builtInDisplay: true))
        #expect(!PairingTraces.trueToneExpected(model: "MacBookAir8,1", appleSilicon: false, builtInDisplay: true))
        #expect(!PairingTraces.trueToneExpected(model: "Mac14,3", appleSilicon: true, builtInDisplay: false))
    }

    @Test func onlyMissingOrUnavailableNeedAttention() {
        let traces = PairingTraces(items: [
            .init(id: "touchID", status: .notEnrolled), .init(id: "trueTone", status: .unavailable),
            .init(id: "camera", status: .missing), .init(id: "lightSensor", status: .working),
        ])
        #expect(traces.problems.map(\.id) == ["trueTone", "camera"])
        #expect(DeviceText.pairing(traces).filter(\.2).count == 2)
    }
}
