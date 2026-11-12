import Foundation
import Testing
@testable import FixStatCore
import MacSensors

@Suite struct UpdateCheckerTests {
    @Test func versionOrder() {
        #expect(UpdateChecker.isNewer("1.3", than: "1.2.1"))
        #expect(UpdateChecker.isNewer("1.10.0", than: "1.9.2"))
        #expect(UpdateChecker.isNewer("1.2.1", than: "1.2"))
        #expect(!UpdateChecker.isNewer("1.2.1", than: "1.2.1"))
        #expect(!UpdateChecker.isNewer("1.2", than: "1.2.0"))
        #expect(!UpdateChecker.isNewer("1.1.9", than: "1.2"))
    }

    @Test func parsesTheReleasesAPI() throws {
        // Shape of api.github.com/repos/Lapsely/fixstat/releases/latest (checked 2026-10-07).
        let json = #"{"tag_name":"v1.2.1","html_url":"https://github.com/Lapsely/fixstat/releases/tag/v1.2.1","draft":false,"prerelease":false,"name":"FixStat 1.2.1"}"#
        let release = try #require(UpdateChecker.parse(Data(json.utf8)))
        #expect(release.version == "1.2.1")
        #expect(release.url.absoluteString.hasSuffix("/v1.2.1"))
        let beta = #"{"tag_name":"v1.3.0-beta","prerelease":true}"#
        #expect(UpdateChecker.parse(Data(beta.utf8)) == nil)
        #expect(UpdateChecker.parse(Data("not json".utf8)) == nil)
    }
}

@Suite struct SensorCheckFanTests {
    static func result(actual: Double, target: Double) -> SensorCheckResult {
        let fans = (0..<10).map { _ in [FanReading(index: 0, actual: actual, minimum: 1200, maximum: 7200, target: target)] }
        return SensorCheck.result(sensors: [], series: [], idleSamples: 10, fans: fans, seconds: 60, missing: [],
                                  missingNames: [:], thermal: nil, load: nil)
    }

    @Test func fanOutOfControlIsNotBlamedOnASensor() {
        let r = Self.result(actual: 7500, target: 0)
        #expect(r.fansRunningAway.count == 1)
        #expect(r.fansNearMax.isEmpty)
        #expect(!r.passed)
        #expect(SensorCheckText.verdict(r) == L("No broken sensor found, but a fan is out of the SMC's control."))
    }

    @Test func fanTheSMCDrivesHardPointsToASensor() {
        let r = Self.result(actual: 7000, target: 7000)
        #expect(r.fansRunningAway.isEmpty)
        #expect(r.fansNearMax.count == 1)
    }

    @Test func fanWithoutTachSignalIsReportedAsAFan() {
        let r = Self.result(actual: 0, target: 1200)
        #expect(r.fansStalled.count == 1)
        #expect(r.fansStalled.first?.target == 1200)
        #expect(!r.passed)
        #expect(SensorCheckText.verdict(r) == L("No broken sensor found, but a fan reads 0 rpm although the SMC asks it to turn."))
    }

    @Test func fanStoppedAtIdleIsFine() {
        // Apple Silicon fans stop at idle: target 0, 0 rpm.
        let r = Self.result(actual: 0, target: 0)
        #expect(r.fansStalled.isEmpty)
        #expect(r.passed)
    }
}
