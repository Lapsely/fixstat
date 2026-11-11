import Foundation
import Testing
@testable import FixStatCore

/// Lines from this M1 Air's log (10 Nov 2026, a dark wake that overheated).
@Suite struct ThermalHistoryTests {
    static let log = """
    Timestamp               Ty Process[PID:TID]
    2026-11-10 19:18:24.312 Df thermalmonitord[139:7aa] mTPL = 1
    2026-11-10 19:18:26.312 Df thermalmonitord[139:7aa] mTPL = 2
    2026-11-10 19:18:28.307 Df thermalmonitord[139:7aa] mTPL = 3
    2026-11-10 19:18:29.311 Df thermalmonitord[139:7aa] mTPL = 2
    2026-11-10 19:18:31.312 Df thermalmonitord[139:7aa] mTPL = 1
    2026-11-10 19:18:33.312 Df thermalmonitord[139:7aa] mTPL = 0
    2026-11-10 19:18:39.312 Df thermalmonitord[139:7aa] mTPL = 1
    2026-11-10 19:18:41.312 Df thermalmonitord[139:7aa] mTPL = 2
    2026-11-10 19:18:43.310 Df thermalmonitord[139:7aa] mTPL = 3
    2026-11-10 19:18:44.312 Df thermalmonitord[139:7aa] mTPL = 4
    2026-11-10 19:18:50.000 Df thermalmonitord[139:7aa] mTPL = 0
    """
    static let pmset = "2026-11-10 19:18:43 +0300 Sleep               \tEntering Sleep state due to 'Dark Wake Thermal Emergency':TCPKeepAlive=active Using AC (Charge:98%) 900 secs"
    static let now = ThermalHistory.formatter.date(from: "2026-11-11 10:00:00")!

    @Test func episodesAreMergedAndLevelsTimed() {
        let h = ThermalHistory.parse(log: Self.log, pmsetLog: Self.pmset, sourceAvailable: true, days: 7, now: Self.now)
        #expect(h.episodes.count == 1)          // 6 s apart: one episode
        #expect(h.episodes.first?.peak == 4)
        #expect(h.emergencySleeps.count == 1)
        #expect(h.secondsAtLevel[3] == 0) // the forced sleep (19:18:43) ends level 4 at once
        #expect(h.needsAttention)
    }

    @Test func timeAsleepIsNotCounted() {
        // Level 4, the forced sleep at 19:18:50, the next level 15 minutes later after the wake.
        let log = """
        2026-11-10 19:18:44.312 Df thermalmonitord[139:7aa] mTPL = 4
        2026-11-10 19:33:52.000 Df thermalmonitord[139:7aa] mTPL = 0
        """
        let pmset = "2026-11-10 19:18:50 +0300 Sleep               \tEntering Sleep state due to 'Dark Wake Thermal Emergency'"
        let h = ThermalHistory.parse(log: log, pmsetLog: pmset, sourceAvailable: true, days: 7, now: Self.now)
        #expect(h.heavySeconds == 6)
        #expect(h.episodes.first?.seconds == 6)
    }

    @Test func theRealDarkWake() {
        // As logged: the sleep at 19:18:43, level 4 at 19:18:44.312, level 0 after the wake at 19:33:44.
        let log = Self.log.replacingOccurrences(of: "2026-11-10 19:18:50.000 Df thermalmonitord[139:7aa] mTPL = 0",
                                                with: "2026-11-10 19:33:44.476 Df thermalmonitord[139:7aa] mTPL = 0")
        let h = ThermalHistory.parse(log: log, pmsetLog: Self.pmset, sourceAvailable: true, days: 7, now: Self.now)
        #expect(h.heavySeconds < 10)
        #expect(h.episodes.first.map { $0.seconds < 30 } == true)
    }

    @Test func aQuietLog() {
        let h = ThermalHistory.parse(log: "", pmsetLog: "", sourceAvailable: true, days: 7, now: Self.now)
        #expect(h.episodes.isEmpty && !h.needsAttention && h.sourceAvailable)
        let none = ThermalHistory.parse(log: "", pmsetLog: "", sourceAvailable: false, days: 7, now: Self.now)
        #expect(!none.sourceAvailable)
    }

    @Test func moderateOnlyIsNotAProblem() {
        let log = """
        2026-11-10 10:00:00.000 Df thermalmonitord[139:7aa] mTPL = 1
        2026-11-10 10:05:00.000 Df thermalmonitord[139:7aa] mTPL = 0
        """
        let h = ThermalHistory.parse(log: log, pmsetLog: "", sourceAvailable: true, days: 7, now: Self.now)
        #expect(h.episodes.count == 1 && h.heavySeconds == 0 && !h.needsAttention)
    }
}
