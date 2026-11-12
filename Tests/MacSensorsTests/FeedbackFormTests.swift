import Foundation
import Testing
@testable import FixStatCore
@testable import MacSensors

@Suite struct FeedbackFormTests {
    let system = SystemInfo(model: "Mac14,2", marketingName: "MacBook Air (M2, 2022)", boardTarget: nil, chip: "Apple M2",
                            architecture: "arm64", isAppleSilicon: true, osVersion: "27.0.1")

    func query(_ url: URL?) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] { result[item.name] = item.value }
        return result
    }

    @Test func generalFeedbackLeavesTheTypeOpen() {
        let q = query(FeedbackForm.general(system: system))
        #expect(q["usp"] == "pp_url")
        #expect(q[FeedbackForm.Entry.type] == nil)
        #expect(q[FeedbackForm.Entry.model] == "Mac14,2")
        #expect(q[FeedbackForm.Entry.macOS] == "27.0.1")
    }

    @Test func plusSignsSurvive() {
        let url = FeedbackForm.url(kind: .bug, model: "x", macOS: "y", appVersion: "z", details: "a+b c")
        #expect(url!.absoluteString.contains("a%2Bb"))
        #expect(query(url)[FeedbackForm.Entry.details] == "a+b c")
    }

    @Test func batteryReportHasNoSerialOrLotCodes() {
        var b = BatteryInfo()
        b.gaugeDeviceName = "bq40z651"
        b.designCapacity = 4382
        b.serial = "F8Y12345ABCDEFGHI" // privacy:allow (made up)
        b.identity = BatteryIdentity(chemistryID: 21353, manufacturerStrings: ["LOT9876", "ATL"], dataFlashWriteCount: nil)
        let check = PartCheck(verdict: .unknown, items: [
            PartCheck.Item(id: "noReference", status: .info, detail: "Mac14,2"),
            PartCheck.Item(id: "manufacturerData", status: .pass, detail: "LOT9876 · ATL"),
            PartCheck.Item(id: "serial", status: .pass, detail: ""),
        ])
        let url = FeedbackForm.battery(b, check: check, system: system)
        let q = query(url)
        #expect(q[FeedbackForm.Entry.type] == "Unknown battery")
        let details = q[FeedbackForm.Entry.details] ?? ""
        #expect(details.contains("gauge: bq40z651"))
        #expect(details.contains("chemistry: 21353"))
        #expect(details.contains("cell maker: ATL"))
        #expect(!details.contains("LOT9876"))
        #expect(!details.contains("F8Y"))
        #expect(!details.contains("serial"))
        #expect(!url!.absoluteString.contains("F8Y"))
    }

    @Test func onlyUnconfirmedPartsOfferAReport() {
        #expect(!FeedbackForm.offersReport(PartCheck(verdict: .consistent, items: [])))
        #expect(FeedbackForm.offersReport(PartCheck(verdict: .unknown, items: [])))
        #expect(FeedbackForm.offersReport(PartCheck(verdict: .suspicious, items: [])))
    }

    @Test func longDetailsAreCut() {
        let url = FeedbackForm.url(kind: .other, model: "m", macOS: "o", appVersion: "a",
                                   details: String(repeating: "x", count: 5000))
        #expect((query(url)[FeedbackForm.Entry.details]?.count ?? 0) <= FeedbackForm.detailsLimit + 1)
    }
}
