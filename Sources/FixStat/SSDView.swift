import Charts
import MacSensors
import SwiftUI
import FixStatCore

/// SwiftUI view of the core `SSDRunner` (write–verify test).
@available(macOS 14.0, *)
@MainActor
@Observable
final class SSDTestRunner {
    typealias State = SSDRunner.State

    private(set) var state = State.idle
    private(set) var phase = SSDStressTest.Phase.write
    private(set) var fraction = 0.0
    /// MB/s per chunk, in chunk order.
    private(set) var writeSpeeds: [Double] = []
    private(set) var readSpeeds: [Double] = []
    private(set) var result: SSDStressTest.Result?

    @ObservationIgnored private let runner: SSDRunner
    @ObservationIgnored private let monitor: Monitor

    init(monitor: Monitor) {
        self.monitor = monitor
        runner = SSDRunner(monitor: monitor.core)
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func start(gigabytes: Double) { runner.start(gigabytes: gigabytes) }
    func stop() { runner.stop() }

    private func sync() {
        if runner.state != state { state = runner.state }
        if runner.phase != phase { phase = runner.phase }
        fraction = runner.fraction
        if runner.writeSpeeds != writeSpeeds { writeSpeeds = runner.writeSpeeds }
        if runner.readSpeeds != readSpeeds { readSpeeds = runner.readSpeeds }
        if runner.result != result {
            result = runner.result
            monitor.lastSSDResult = runner.result
        }
    }
}

/// SSD identity, health (SMART), other drives, the write–verify stress test and the full test.
@available(macOS 14.0, *)
struct SSDView: View {
    static let windowID = "ssd"

    @Environment(SSDTestRunner.self) private var runner
    @Environment(FullSSDTestRunner.self) private var fullRunner
    @State private var info = SSDInfo.read()
    @State private var gigabytes = 8.0
    @State private var watcher = StorageWatcher()
    @State private var volumes = USBVolumes.mounted()
    @State private var capacity = CapacityModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let info {
                    identity(info)
                    if let health = info.health {
                        HealthCard(summary: SSDText.healthSummary(info), findings: SSDText.healthFindings(health),
                                   rows: SSDText.healthRows(health), attributes: nil)
                    } else if let ata = info.ata {
                        HealthCard(summary: SSDText.healthSummary(info), findings: SSDText.ataFindings(ata),
                                   rows: SSDText.ataRows(ata), attributes: SSDText.ataTable(ata))
                    } else {
                        Card {
                            CardHeader("Health (SMART)", systemImage: "heart.text.square")
                            Text("SMART data is not available for this SSD.").foregroundStyle(.secondary)
                            if SSDText.needsFullDiskAccess(info) {
                                Label(SSDText.fullDiskAccessHint, systemImage: "lock.shield")
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Open System Settings") { FullSSDTestRunner.openFullDiskAccessSettings() }
                            }
                            if let problem = info.smartProblem {
                                Text(verbatim: problem).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if !info.otherDrives.isEmpty {
                        Card {
                            CardHeader("Other internal drives", systemImage: "internaldrive")
                            ForEach(Array(info.otherDrives.enumerated()), id: \.offset) { _, drive in
                                let problems = drive.health.map(SSDText.ataFindings)?.isEmpty == false
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: drive.model ?? "–")
                                        .foregroundStyle(problems ? TemperatureColor.hot : .primary)
                                    Text(verbatim: SSDText.driveSummary(drive)).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Text("No internal SSD found.").foregroundStyle(.secondary)
                }
                externalDrives
                realCapacity
                stressTest
                Card {
                    FullSSDTestSection(writeVerifyGigabytes: gigabytes)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 600)
        .monospacedDigit()
        .onChange(of: runner.state) { _, state in
            if state == .finished { info = SSDInfo.read() }
        }
        .onAppear {
            watcher.onChange = { MainActor.assumeIsolated {
                info = SSDInfo.read()
                volumes = USBVolumes.mounted()
            } }
            watcher.start()
        }
        .onDisappear { watcher.stop() }
    }

    // MARK: Real capacity

    private var realCapacity: some View {
        Card {
            CardHeader("Real capacity", systemImage: "checkmark.seal") { InfoButton(.ssdRealCapacity) }
            Text("Finds fake USB sticks and cards that hold less than they report.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if volumes.isEmpty {
                Text("Plug in a USB stick, card or external drive to check its capacity.").foregroundStyle(.secondary)
            }
            ForEach(volumes, id: \.bsdName) { volume in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: volume.name)
                        Text(verbatim: [volume.device.name, String(localized: "\(Format.bytes(Double(volume.availableBytes))) free"),
                                        CapacityCheckText.estimate(CapacityCheckRunner.estimate(volume))]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check capacity") { capacity.start(volume) }
                        .disabled(capacity.running || !CapacityCheckRunner.hasSpace(volume))
                }
                if let result = capacity.results[volume.name] {
                    ForEach(Array(CapacityCheckText.rows(result).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: row.0).frame(width: 140, alignment: .leading).foregroundStyle(.secondary)
                            Text(verbatim: row.1)
                        }
                        .font(.callout)
                    }
                    let verdict = CapacityCheckText.verdict(result)
                    Label(verdict.0, systemImage: verdict.1 ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(verdict.1 ? TemperatureColor.hot : TemperatureColor.cool)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if capacity.running {
                HStack {
                    ProgressView(value: capacity.fraction) { Text(verbatim: capacity.progress).font(.caption) }
                    Button("Stop", role: .cancel) { capacity.stop() }
                }
            }
        }
    }

    // MARK: External drives

    private var externalDrives: some View {
        Card {
            CardHeader("External drives", systemImage: "externaldrive")
            let drives = info?.externalDrives ?? []
            if drives.isEmpty {
                Text("No external drive connected. Plug one in: the list updates by itself.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(drives.enumerated()), id: \.offset) { index, drive in
                if index > 0 { Divider() }
                ExternalDriveView(drive: drive)
            }
        }
    }

    private func identity(_ info: SSDInfo) -> some View {
        VStack(alignment: .leading, spacing: Design.cardSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: info.model ?? "SSD").font(.title3.weight(.medium))
                Text(verbatim: SSDText.identity(info)).foregroundStyle(.secondary)
            }
            HStack(spacing: Design.cardSpacing) {
                MetricTile(title: "Health", value: info.healthPercent.map { Format.percent(Double($0)) }
                           ?? (info.ata != nil ? String(localized: "not known") : "–"))
                if let space = info.space {
                    MetricTile(title: "Free space", value: Format.bytes(space.available))
                }
                if let io = info.io {
                    MetricTile(title: "Errors since startup", value: Format.number(Double(io.errors + io.retries)))
                }
            }
            if let space = info.space {
                Text(verbatim: SSDText.space(space)).foregroundStyle(.secondary)
            }
            if let io = info.io {
                if let finding = SSDText.ioFinding(io) {
                    FindingRow(text: finding)
                } else {
                    Text(verbatim: SSDText.io(io)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Stress test

    private var stressTest: some View {
        let available = Double(SSDRunner.availableBytes) / 1_000_000_000
        return Card {
            CardHeader("Write–verify stress test", systemImage: "arrow.triangle.2.circlepath") { InfoButton(.ssdStressTest) }
            Text("Writes test data to free space, reads it back and compares it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = SSDText.testLocationNote {
                Label(note, systemImage: "externaldrive")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Picker("Size", selection: $gigabytes) {
                    ForEach([2.0, 8.0, 16.0, 32.0], id: \.self) { size in
                        Text(verbatim: Format.bytes(size * 1_000_000_000)).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(runner.state == .running)
                Text("\(Format.bytes(available * 1_000_000_000)) usable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if runner.state == .running {
                    Button("Stop", role: .cancel) { runner.stop() }
                } else {
                    Button("Start test") { runner.start(gigabytes: gigabytes) }
                        .buttonStyle(.borderedProminent)
                        .disabled(available < 1 || fullRunner.isRunning)
                }
            }
            .padding(.top, 4)
            if runner.state == .running {
                ProgressView(value: runner.fraction) {
                    Text(runner.phase == .write ? "Writing…" : "Reading and verifying…").font(.caption)
                }
            }
            if !runner.writeSpeeds.isEmpty {
                speedChart
            }
            if let result = runner.result {
                SSDResultView(result: result)
            }
        }
    }

    private var speedChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speed per 8 MB block").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Label("Write", systemImage: "circle.fill").foregroundStyle(TemperatureColor.hot)
                Label("Read", systemImage: "circle.fill").foregroundStyle(TemperatureColor.cool)
            }
            .font(.caption)
            Chart {
                // The SSD's own cache makes single write blocks spiky; show a moving average.
                ForEach(Array(SSDRunner.movingAverage(runner.writeSpeeds, window: 8).enumerated()), id: \.offset) { index, speed in
                    LineMark(x: .value("Block", index), y: .value("MB/s", speed), series: .value("Phase", "write"))
                        .foregroundStyle(TemperatureColor.hot)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                ForEach(Array(runner.readSpeeds.enumerated()), id: \.offset) { index, speed in
                    LineMark(x: .value("Block", index), y: .value("MB/s", speed), series: .value("Phase", "read"))
                        .foregroundStyle(TemperatureColor.cool)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Format.speed(megabytesPerSecond: value.as(Double.self) ?? 0)) }
                }
            }
            .frame(height: 150)
        }
    }
}

/// SMART values with an assessment.
@available(macOS 14.0, *)
private struct HealthCard: View {
    let summary: String?
    let findings: [String]
    let rows: [(String, String)]
    /// ATA SMART attribute table (technician detail), nil for NVMe.
    let attributes: [[String]]?

    var body: some View {
        Card {
            CardHeader("Health (SMART)", systemImage: "heart.text.square")
            if let summary {
                let parts = SSDText.splitSummary(summary)
                Text(verbatim: parts.title).font(.headline)
                if let detail = parts.detail {
                    Text(verbatim: detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if findings.isEmpty {
                FindingRow(text: String(localized: "SSD health is good."), problem: false)
            } else {
                ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                    FindingRow(text: finding)
                }
            }
            SMARTRows(rows: rows)
            if let attributes {
                SMARTAttributeTable(attributes: attributes)
            }
        }
    }
}

/// SMART values in two columns.
@available(macOS 14.0, *)
private struct SMARTRows: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: Design.rowSpacing) {
            ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { index in
                GridRow {
                    SMARTRow(row: rows[index])
                    if index + 1 < rows.count {
                        SMARTRow(row: rows[index + 1])
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

/// One SMART value with its ⓘ explanation.
@available(macOS 14.0, *)
private struct SMARTRow: View {
    let row: (String, String)

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: row.0).foregroundStyle(.secondary).lineLimit(1)
                .info(Glossary.term(forSSDRow: row.0))
            Spacer(minLength: 8)
            Text(verbatim: row.1).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 1)
    }
}

/// Every ATA SMART attribute, collapsed.
@available(macOS 14.0, *)
private struct SMARTAttributeTable: View {
    let attributes: [[String]]

    var body: some View {
        DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    ForEach(SSDText.ataTableHeader, id: \.self) { Text(verbatim: $0).foregroundStyle(.secondary) }
                }
                ForEach(Array(attributes.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(verbatim: cell) }
                    }
                }
            }
            .font(.caption.monospaced())
            .padding(.top, 4)
        } label: {
            Text("All SMART attributes").foregroundStyle(.secondary)
        }
    }
}

/// One external drive: identity, health, findings, SMART values or why there are none.
@available(macOS 14.0, *)
private struct ExternalDriveView: View {
    let drive: ATADrive

    var body: some View {
        let findings = SSDText.externalFindings(drive)
        VStack(alignment: .leading, spacing: Design.rowSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: drive.model ?? "–").font(.headline)
                    .foregroundStyle(findings.isEmpty ? .primary : TemperatureColor.hot)
                Text(verbatim: SSDText.externalIdentityShort(drive)).foregroundStyle(.secondary)
                let technical = SSDText.externalIdentityTechnical(drive)
                if !technical.isEmpty {
                    Text(verbatim: technical).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
            if SSDText.externalHasSMART(drive) {
                if let summary = SSDText.externalHealthSummary(drive) {
                    let parts = SSDText.splitSummary(summary)
                    Text(verbatim: parts.title).fontWeight(.semibold)
                    if let detail = parts.detail {
                        Text(verbatim: detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if findings.isEmpty {
                    FindingRow(text: String(localized: "SSD health is good."), problem: false)
                }
            }
            ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                FindingRow(text: finding)
            }
            if let problem = SSDText.externalSMARTProblem(drive) {
                Text(verbatim: problem).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if SSDText.needsFullDiskAccess(drive) {
                    Label(SSDText.fullDiskAccessHint, systemImage: "lock.shield")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { FullSSDTestRunner.openFullDiskAccessSettings() }
                }
            }
            if let io = drive.io, SSDText.ioFinding(io) == nil {
                Text(verbatim: SSDText.io(io)).font(.callout).foregroundStyle(.secondary)
            }
            if SSDText.externalHasSMART(drive) {
                SMARTRows(rows: SSDText.externalHealthRows(drive))
            }
            if let attributes = SSDText.externalAttributes(drive) {
                SMARTAttributeTable(attributes: attributes)
            }
        }
    }
}

@available(macOS 14.0, *)
struct SSDResultView: View {
    let result: SSDStressTest.Result

    var body: some View {
        VStack(alignment: .leading, spacing: Design.rowSpacing) {
            let problems = result.findings.filter { $0 != .stoppedEarly }
            FindingRow(text: problems.isEmpty ? String(localized: "No problems found") : String(localized: "Needs attention"),
                       problem: !problems.isEmpty)
                .font(.headline)
            ForEach(Array(result.findings.enumerated()), id: \.offset) { _, finding in
                Text(verbatim: "• " + SSDText.finding(finding))
            }
            ForEach(Array(SSDText.resultRows(result).enumerated()), id: \.offset) { _, row in
                CardRow(title: Text(verbatim: row.0), value: row.1)
            }
        }
        .padding(.top, 6)
    }
}

/// SwiftUI view of the core `CapacityCheckRunner`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class CapacityModel {
    private(set) var running = false
    private(set) var fraction = 0.0
    private(set) var progress = ""
    private(set) var results: [String: CapacityCheck.Result] = [:]
    @ObservationIgnored private let runner = CapacityCheckRunner()

    init() {
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func start(_ volume: USBVolume) { runner.start(volume) }
    func stop() { runner.stop() }

    private func sync() {
        running = runner.state == .running
        fraction = runner.fraction
        progress = CapacityCheckText.progress(runner)
        if runner.results != results { results = runner.results }
    }
}
