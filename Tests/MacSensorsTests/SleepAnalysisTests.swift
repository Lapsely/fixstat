import Foundation
import Testing
@testable import MacSensors

@Suite struct SleepAnalysisTests {
    static let log = """
        2026-09-25 11:31:59 +0300 Sleep               \tEntering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using Batt (Charge:80%) 7200 secs
        2026-09-25 12:10:00 +0300 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to RTC/Maintenance Using BATT (Charge:79%) 45 secs
        2026-09-25 12:10:45 +0300 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:79%) 4000 secs
        2026-09-25 13:31:59 +0300 Wake                \tWake from Normal Sleep [CDNVA] : due to EC.LidOpen/Lid Open Using BATT (Charge:77%)
        2026-09-25 13:32:00 +0300 WakeTime            \tWakeTime: 3.235 sec
        2026-09-25 13:32:00 +0300 Kernel Client Acks  \tDelays to Wake notifications: [AppleSEPManager driver is slow(msg: SetState to 2)(330 ms)] [CoreKDLDriver driver is slow(msg: SetState to 1)(3233 ms)]
        2026-09-25 13:40:00 +0300 Assertions          \tPID 29772(Claude) Released NoIdleSleepAssertion "Electron" 01:06:44  id:0x0x10000992c [System: PrevIdle DeclUser kDisp]
        2026-09-25 13:41:00 +0300 Assertions          \tPID 108(powerd) Released PreventUserIdleSystemSleep "Powerd" 02:00:00  id:0x1 [System: PrevIdle]
        2026-09-25 14:00:00 +0300 BatteryHealth       \tWarning level: 2 time: 30 cap: 10
        2026-09-26 11:01:10 +0300 Sleep               \tEntering Sleep state due to 'Low Power Sleep':TCPKeepAlive=inactive Using Batt (Charge:1%) 24 secs
        2026-09-26 11:01:34 +0300 Wake                \tWake from Hibernate [CDNVA] : due to acattach/UserActivity Assertion Using AC (Charge:1%)
        """

    @Test func parsesEvents() {
        let a = SleepAnalysis.parse(log: Self.log)
        #expect(a.sleeps.count == 3)
        #expect(a.wakes.count == 2)
        #expect(a.darkWakes.count == 1)
        #expect(a.lowPowerSleeps == 1)
        #expect(a.sleeps[0].reason == "Idle Sleep")
        #expect(a.sleeps[0].charge == 80)
        #expect(a.sleeps[0].onBattery == true)
        #expect(a.sleeps[0].duration == 7200)
        #expect(a.darkWakes[0].reason == "RTC/Maintenance")
        #expect(a.darkWakes[0].duration == 45)
        #expect(a.wakes[0].reason == "EC.LidOpen/Lid Open")
        #expect(a.wakes[1].onBattery == false)
        #expect(a.averageWakeTime == 3.235)
        #expect(a.lowBatteryWarnings == 1)
        #expect(a.reasons(.wake).count == 2)
    }

    @Test func drainAndDrivers() {
        let a = SleepAnalysis.parse(log: Self.log)
        // Sleep at 80 % to the lid opening at 77 % two hours later, the dark wake included; the
        // 24 s sleep is too short.
        let drain = a.sleepDrain!
        #expect(drain.segments == 1)
        #expect(abs(drain.percentPerHour - 1.5) < 0.01)
        #expect(a.slowDrivers.first?.driver == "AppleSEPManager" || a.slowDrivers.first?.driver == "CoreKDLDriver")
        #expect(a.slowDrivers.contains { $0.driver == "CoreKDLDriver" && $0.maxMilliseconds == 3233 })
        #expect(a.preventers == [.init(process: "Claude", count: 1, longestSeconds: 4004)])
    }

    @Test func settings() {
        let text = """
            System-wide power settings:
            Currently in use:
             standby              1
             Sleep On Power Button 1
             sleep                1 (sleep prevented by powerd, Claude)
             displaysleep         0
            """
        let (settings, preventing) = SleepAnalysis.parseSettings(text)
        #expect(settings["standby"] == "1")
        #expect(settings["sleep"] == "1")
        #expect(settings["Sleep On Power Button"] == "1")
        #expect(settings["displaysleep"] == "0")
        #expect(preventing == ["powerd", "Claude"])
    }

    @Test func systemWideSleepDisabled() {
        // `pmset -g` on a bench Mac set never to sleep (MacBookAir6,1, macOS 11): tab separated.
        let text = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep                1\n"
        #expect(SleepAnalysis.parseSettings(text).settings["SleepDisabled"] == "1")
    }
}

@Suite struct OffStateDrainTests {
    static let log = """
        2026-09-24 09:49:37 +0300 Assertions          \tSummary- [System: PrevIdle DeclUser kDisp] Using Batt(Charge: 17)
        2026-09-24 14:25:09 +0300 Start               \tpowerd process is started
        2026-09-24 14:25:09 +0300 Assertions          \tSummary- [System: No Assertions] Using AC(Charge: 15)
        2026-09-25 08:00:00 +0300 Assertions          \tSummary- [System: No Assertions] Using Batt(Charge: 40)
        2026-09-25 12:00:00 +0300 Assertions          \tSummary- [System: No Assertions] Using AC(Charge: 38)
        """

    static func date(_ s: String) -> Date { SleepAnalysis.dateFormatter.date(from: s)! }

    @Test func fromLog() {
        let records: [(date: Date, isBoot: Bool)] = [
            (Self.date("2026-09-24 10:01:55 +0300"), false),
            (Self.date("2026-09-24 14:25:04 +0300"), true),
            // Power loss: no shutdown record before this boot.
            (Self.date("2026-09-25 11:59:00 +0300"), true),
        ]
        let periods = OffStateDrain.fromLog(Self.log, records: records, fullChargeCapacity: 3200)
        #expect(periods.count == 2)
        #expect(periods[0].chargeBefore == 17)
        #expect(periods[0].chargeAfter == 15)
        #expect(!periods[0].shutdownEstimated)
        #expect(abs(periods[0].hours - 4.386) < 0.01)
        #expect(abs((periods[0].lostMAh ?? 0) - 64) < 0.01)
        #expect(periods[1].shutdownEstimated)
        #expect(periods[1].shutdown == Self.date("2026-09-25 08:00:00 +0300"))
        let summary = OffStateDrain.summary(periods)!
        #expect(abs(summary.hours - (4.386 + 3.983)) < 0.01)
        #expect(abs((summary.percentPerHour ?? 0) - 4 / summary.hours) < 0.001)
    }

    @Test func measured() {
        let mark = OffStateDrain.PowerOffMark(date: Self.date("2026-09-24 20:00:00 +0300"), remaining: 2000,
                                              charge: 62, fullChargeCapacity: 3200)
        let boot = Self.date("2026-09-25 08:00:00 +0300")
        let period = OffStateDrain.measured(mark: mark, records: [(boot, true)], now: boot.addingTimeInterval(60),
                                            remaining: 1964, charge: 61)!
        #expect(period.averageCurrent == 3) // 36 mAh in 12 h
        #expect(period.isUsable)
        #expect(OffStateDrain.measured(mark: mark, records: [(boot, true)], now: boot.addingTimeInterval(3600),
                                       remaining: 1964, charge: 61) == nil)
    }

    @Test func runningboardAssertionNamesTheApp() {
        #expect(SleepAnalysis.target(ofAssertion: "\"app<application.com.apple.Safari.145132.145798(501)>:fetch\"") == "Safari")
        #expect(SleepAnalysis.target(ofAssertion: "osservice<com.apple.mobileassetd>176-344") == "mobileassetd")
        #expect(SleepAnalysis.target(ofAssertion: "com.apple.audio.context271.preventuseridlesleep") == nil)
        // A bundle id no Mac has installed: the name comes from the id, whatever the test Mac has
        // (with Google Chrome installed, "com.google.Chrome" reads "Google Chrome").
        let log = "2026-11-25 09:19:44 +0300 Assertions          \tPID 176(runningboardd) Released PreventUserIdleSystemSleep "
            + "\"app<application.org.fixstat-test.Player.1.2(501)>:media\" 00:42:00  id:0x0x1000080aa [System: PrevIdle]"
        let a = SleepAnalysis.parse(log: log)
        #expect(a.preventers.first?.process == "runningboardd → Player")
        #expect(a.preventers.first?.longestSeconds == 2520)
    }

    @Test func currentAssertionsNameTheAppBehindCoreAudio() {
        let text = """
            Listed by owning process:
               pid 374(coreaudiod): [0x00004ece00018319] 00:00:10 PreventUserIdleSystemSleep named: "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep"
            \tCreated for PID: 6613.
            \tResources: audio-out BuiltInSpeakerDevice
               pid 176(runningboardd): [0x01] 00:00:05 PreventUserIdleSystemSleep named: "app<application.com.spotify.client.9.9(501)>:x"
               pid 130(mds): [0x02] 00:00:22 BackgroundTask named: "com.apple.metadata.mds.power"
            \tCreated for PID: 1.
            """
        let behalf = SleepAnalysis.onBehalf(assertions: text) { $0 == 6613 ? "Music" : "launchd" }
        #expect(behalf["coreaudiod"] == ["Music"])
        #expect(behalf["runningboardd"] == ["Spotify"])
        #expect(behalf["mds"] == nil)
    }

    @Test func frequentDarkWakesStillCountAsAsleep() {
        // Lid closed at 90 %, a dark wake every 10 minutes for 5 hours, opened at 40 %.
        var lines: [String] = []
        let f = SleepAnalysis.dateFormatter
        var t = f.date(from: "2026-11-25 22:00:00 +0300")!
        var charge = 90
        lines.append("\(f.string(from: t)) Sleep               \tEntering Sleep state due to 'Clamshell Sleep': Using Batt (Charge:\(charge)%) 600 secs")
        for _ in 0..<30 {
            t += 600; charge -= 1
            lines.append("\(f.string(from: t)) DarkWake            \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake wifibt SMC.OutboxNotEmpty/ Using BATT (Charge:\(charge)%) 6 secs")
            lines.append("\(f.string(from: t + 6)) Sleep               \tEntering Sleep state due to 'Maintenance Sleep': Using Batt (Charge:\(charge)%) 594 secs")
        }
        t += 600
        lines.append("\(f.string(from: t)) Wake                \tWake from Normal Sleep [CDNVA] : due to EC.LidOpen/Lid Open Using BATT (Charge:40%)")
        let drain = SleepAnalysis.parse(log: lines.joined(separator: "\n")).sleepDrain!
        #expect(drain.segments == 1)
        #expect(abs(drain.hours - 31.0 / 6) < 0.01)
        #expect(drain.percentPerHour > 9)
    }
}
