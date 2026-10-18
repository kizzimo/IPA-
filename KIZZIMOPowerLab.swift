import SwiftUI
import Combine
import UIKit
import QuartzCore
import Metal
import UniformTypeIdentifiers

// KIZZIMO iOS FULL CONTROL — NATIVE v2.0
// Supported public APIs only. All scheduling/power activity changes are APP-LOCAL.

struct LabRecord: Codable, Identifiable {
    let id: UUID
    let when: Date
    let test: String
    let result: String
    let lowPower: Bool
    let thermal: String
    let battery: Int
    init(test: String, result: String, lowPower: Bool, thermal: String, battery: Int) {
        id = UUID(); when = Date(); self.test = test; self.result = result
        self.lowPower = lowPower; self.thermal = thermal; self.battery = battery
    }
}

struct ExportedReport: Codable {
    let title: String
    let generated: Date
    let iOS: String
    let model: String
    let entries: [LabRecord]
}

@MainActor final class PowerEngine: ObservableObject {
    @Published var lowPower = false
    @Published var thermal = "Unknown"
    @Published var battery = -1
    @Published var charging = false
    @Published var displayMax = 0
    @Published var brightness = 0.5
    @Published var running = false
    @Published var progress = "Ready"
    @Published var records: [LabRecord] = []
    @Published var gpu = "Unavailable"
    @Published var allocatedGPU = "Unavailable"
    let originalBrightness: CGFloat
    private let storageKey = "Kizzimo.PowerLab.v2.records"

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        originalBrightness = UIScreen.main.brightness
        brightness = Double(originalBrightness)
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([LabRecord].self, from: data) {
            records = decoded
        }
        refresh()
    }

    func refresh() {
        let process = ProcessInfo.processInfo
        lowPower = process.isLowPowerModeEnabled
        switch process.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }
        let level = UIDevice.current.batteryLevel
        battery = level < 0 ? -1 : Int((level * 100).rounded())
        charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        displayMax = UIScreen.main.maximumFramesPerSecond
        if let device = MTLCreateSystemDefaultDevice() {
            gpu = device.name
            allocatedGPU = "\(device.currentAllocatedSize / 1_048_576) MiB allocated to this app's Metal device"
        }
    }

    func setBrightness(_ value: Double) {
        let safe = min(1, max(0.05, value))
        UIScreen.main.brightness = CGFloat(safe)
        brightness = safe
    }
    func restoreBrightness() { setBrightness(Double(originalBrightness)) }

    func add(_ test: String, _ result: String) {
        refresh()
        records.insert(LabRecord(test: test, result: result,
                                 lowPower: lowPower, thermal: thermal, battery: battery), at: 0)
        records = Array(records.prefix(150))
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        progress = result
    }
    func eraseRecords() {
        records = []
        UserDefaults.standard.removeObject(forKey: storageKey)
        progress = "Results cleared"
    }

    // An identical, bounded synthetic workload, not a CPU frequency reader.
    @inline(never) nonisolated static func workload(_ count: Int) -> UInt64 {
        var x: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0..<count {
            x ^= x >> 12
            x ^= x << 25
            x ^= x >> 27
            x = x &* 2685821657736338717
        }
        return x
    }

    enum WorkMode: String, CaseIterable, Identifiable {
        case utility = "Utility QoS"
        case initiated = "User-initiated QoS"
        case interactive = "User-interactive QoS"
        case latency = "Latency-critical activity"
        var id: String { rawValue }
        var queueQoS: DispatchQoS.QoSClass {
            switch self {
            case .utility: return .utility
            case .initiated: return .userInitiated
            case .interactive, .latency: return .userInteractive
            }
        }
    }

    func benchmark(_ mode: WorkMode) {
        guard !running else { return }
        running = true; progress = "Running \(mode.rawValue) — 5 bounded samples…"
        let lowAtStart = lowPower
        DispatchQueue.global(qos: mode.queueQoS).async {
            var times: [Double] = []
            var checksum: UInt64 = 0
            let runOne: () -> Void = {
                let begin = DispatchTime.now().uptimeNanoseconds
                checksum ^= Self.workload(1_500_000)
                let end = DispatchTime.now().uptimeNanoseconds
                times.append(Double(end - begin) / 1_000_000)
            }
            // Activity option is scoped ONLY to this benchmark's work.
            if mode == .latency {
                ProcessInfo.processInfo.performActivity(
                    options: [.userInteractive, .latencyCritical],
                    reason: "Brief user-requested KIZZIMO latency test"
                ) {
                    for _ in 0..<5 { runOne() }
                }
            } else {
                for _ in 0..<5 { runOne() }
            }
            let avg = times.reduce(0, +) / Double(times.count)
            let sorted = times.sorted()
            let label = String(format: "%.3f ms mean / %.3f ms worst / checksum %llX", avg, sorted.last ?? 0, checksum)
            DispatchQueue.main.async {
                self.running = false
                self.add(mode.rawValue, label + (lowAtStart ? " [LPM on]" : " [LPM off]"))
            }
        }
    }

    func export() -> URL? {
        let report = ExportedReport(title: "KIZZIMO iOS Native v2.0",
                                    generated: Date(),
                                    iOS: UIDevice.current.systemVersion,
                                    model: UIDevice.current.model,
                                    entries: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KIZZIMO_Power_Report.json")
        do { try data.write(to: url, options: .atomic); return url }
        catch { progress = "Export failed: \(error.localizedDescription)"; return nil }
    }
}

@MainActor final class CadenceSampler: NSObject, ObservableObject {
    @Published var running = false
    @Published var summary = "Run a 6-second callback test. This is this app's display-link cadence, not game FPS."
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var generation = 0
    var onResult: ((String) -> Void)?

    func start() {
        guard !running else { return }
        generation += 1
        let gen = generation
        last = 0; intervals = []
        running = true; summary = "Sampling for 6 seconds…"
        let dl = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let peak = Float(UIScreen.main.maximumFramesPerSecond)
        dl.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: peak, preferred: peak)
        dl.add(to: .main, forMode: .common)
        link = dl
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, self.generation == gen else { return }
            self.finish()
        }
    }
    @objc private func tick(_ dl: CADisplayLink) {
        if last > 0 {
            let dt = (dl.timestamp - last) * 1000
            if dt > 0 && dt < 250 { intervals.append(dt) }
        }
        last = dl.timestamp
    }
    func finish() {
        link?.invalidate(); link = nil; running = false
        guard !intervals.isEmpty else { summary = "No valid samples"; return }
        let sorted = intervals.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
        let gaps = sorted.filter { $0 > 25 }.count
        summary = String(format: "%.1f callbacks/s · %.2f ms mean · P95 %.2f ms · P99 %.2f ms · %d gaps >25 ms · n=%d",
                         1000 / mean, mean, p95, p99, gaps, sorted.count)
        onResult?(summary)
    }
}

final class TouchCaptureView: UIView {
    var record: ((Double) -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let ms = max(0, (CACurrentMediaTime() - touch.timestamp) * 1000)
            if ms < 1000 { record?(ms) }
        }
        super.touchesBegan(touches, with: event)
    }
}
struct TouchSurface: UIViewRepresentable {
    let onEvent: (Double) -> Void
    func makeUIView(context: Context) -> TouchCaptureView {
        let view = TouchCaptureView()
        view.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.18)
        view.layer.cornerRadius = 16
        view.record = onEvent
        view.isMultipleTouchEnabled = true
        return view
    }
    func updateUIView(_ view: TouchCaptureView, context: Context) { view.record = onEvent }
}

struct FileShare: Identifiable { let id = UUID(); let url: URL }
struct SharePanel: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct DaemonTarget: Hashable {
    let group: String
    let label: String
    let risk: String
}
enum DraftOverride: Int, Codable { case disabled = 1, enabled = 0, remove = -1 }

@MainActor final class DaemonDraft: ObservableObject {
    static let catalog: [DaemonTarget] = [
        .init(group: "thermalmonitord", label: "com.apple.thermalmonitord", risk: "CRITICAL"),
        .init(group: "OTA", label: "com.apple.mobile.softwareupdated", risk: "HIGH"),
        .init(group: "OTA", label: "com.apple.OTATaskingAgent", risk: "HIGH"),
        .init(group: "OTA", label: "com.apple.softwareupdateservicesd", risk: "HIGH"),
        .init(group: "OTA", label: "com.apple.mobile.NRDUpdated", risk: "HIGH"),
        .init(group: "UsageTrackingAgent", label: "com.apple.UsageTrackingAgent", risk: "CAUTION"),
        .init(group: "GameCenter", label: "com.apple.gamed", risk: "CAUTION"),
        .init(group: "ScreenTime", label: "com.apple.ScreenTimeAgent", risk: "HIGH"),
        .init(group: "ScreenTime", label: "com.apple.homed", risk: "HIGH"),
        .init(group: "ScreenTime", label: "com.apple.familycircled", risk: "HIGH"),
        .init(group: "ScreenTime", label: "com.apple.familynotification", risk: "HIGH"),
        .init(group: "ScreenTime", label: "com.apple.asktod", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.ReportCrash", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.ReportCrash.Jetsam", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.ReportMemoryException", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.OTACrashCopier", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.analyticsd", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.wifianalyticsd", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.aslmanager", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.coresymbolicationd", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.crash_mover", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.crashreportcopymobile", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.DumpBasebandCrash", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.DumpPanic", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.logd", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.logd.admin", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.logd.events", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.logd.watchdog", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.logd_helper", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.logd_reporter", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.logd_reporter.report_statistics", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.system.logger", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.hangreporter", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.hangtracerd", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.spindump", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.tailspind", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.rtcreportingd", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.syslogd", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.signpost.signpost_reporter", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.pluginkit.pkreporter", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.ProxiedCrashCopier", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.ProxiedCrashCopier.ProxyingDevice", risk: "HIGH"),
        .init(group: "CrashReports", label: "com.apple.ReportSystemMemory", risk: "HIGH"),
        .init(group: "Diagnostics", label: "com.apple.diagnosticd", risk: "HIGH"),
        .init(group: "Diagnostics", label: "com.apple.diagnosticextensionsd", risk: "HIGH"),
        .init(group: "Diagnostics", label: "com.apple.diagnosticservicesd", risk: "HIGH"),
        .init(group: "Diagnostics", label: "com.apple.diagnosticspushd", risk: "HIGH"),
        .init(group: "Diagnostics", label: "com.apple.symptomsd-diag", risk: "HIGH"),
        .init(group: "Diagnostics", label: "com.apple.sysdiagnose", risk: "HIGH"),
        .init(group: "Diagnostics", label: "com.apple.sysdiagnose.darwinos", risk: "HIGH"),
        .init(group: "Diagnostics", label: "com.apple.sysdiagnose_helper", risk: "HIGH"),
        .init(group: "ATWAKEUP", label: "com.apple.atc.atwakeup", risk: "CAUTION"),
        .init(group: "Tips", label: "com.apple.tipsd", risk: "LOW"),
        .init(group: "VPN", label: "com.apple.racoon", risk: "HIGH"),
        .init(group: "Location", label: "com.apple.locationd", risk: "HIGH"),
        .init(group: "ChineseLAN", label: "com.apple.wapic", risk: "CAUTION"),
        .init(group: "ChineseLAN", label: "com.apple.wifi.wapic", risk: "CAUTION"),
        .init(group: "HealthKit", label: "com.apple.healthd", risk: "HIGH"),
        .init(group: "AirPrint", label: "com.apple.printd", risk: "LOW"),
        .init(group: "AssistiveTouch", label: "com.apple.assistivetouchd", risk: "HIGH"),
        .init(group: "iCloud", label: "com.apple.itunescloudd", risk: "HIGH"),
        .init(group: "InternetTethering", label: "com.apple.MobileInternetSharing", risk: "CAUTION"),
        .init(group: "PassBook", label: "com.apple.passd", risk: "HIGH"),
        .init(group: "Spotlight", label: "com.apple.searchd", risk: "HIGH"),
        .init(group: "Spotlight", label: "com.apple.corespotlightservice", risk: "HIGH"),
        .init(group: "Spotlight", label: "com.apple.spotlightknowledged", risk: "HIGH"),
        .init(group: "Spotlight", label: "com.apple.spotlightknowledged.updater", risk: "HIGH"),
        .init(group: "Spotlight", label: "com.apple.spotlight.IndexAgent", risk: "HIGH"),
        .init(group: "VoiceControl", label: "com.apple.assistant_service", risk: "HIGH"),
        .init(group: "VoiceControl", label: "com.apple.assistantd", risk: "HIGH"),
        .init(group: "VoiceControl", label: "com.apple.voiced", risk: "HIGH"),
        .init(group: "NanoTimeKit", label: "com.apple.nanotimekitcompaniond", risk: "CAUTION"),
        .init(group: "FollowUp", label: "com.apple.followupd", risk: "CAUTION"),
        .init(group: "Default baseline", label: "com.apple.magicswitchd.companion", risk: "REVIEW"),
        .init(group: "Default baseline", label: "com.apple.security.otpaird", risk: "REVIEW"),
        .init(group: "Default baseline", label: "com.apple.dhcp6d", risk: "REVIEW"),
        .init(group: "Default baseline", label: "com.apple.bootpd", risk: "REVIEW"),
        .init(group: "Default baseline", label: "com.apple.ftp-proxy-embedded", risk: "REVIEW"),
        .init(group: "Default baseline", label: "com.apple.relevanced", risk: "REVIEW"),
    ]
    @Published var sourceName = "Blank draft"
    @Published var query = ""
    @Published var customID = ""
    @Published var message = "Exporting a draft cannot apply it to protected iOS paths."
    @Published var edits: [String: DraftOverride] = [:]
    @Published var customTargets: [DaemonTarget] = []
    private var sourceRoot: [String: Any] = [:]

    var filtered: [DaemonTarget] {
        let imported = sourceRoot.keys.filter { key in
            key.hasPrefix("com.") && !Self.catalog.contains(where: { $0.label == key })
        }.map { DaemonTarget(group: "Imported", label: $0, risk: "UNVERIFIED") }
        let result = Self.catalog + imported + customTargets
        let unique = Dictionary(result.map { ($0.label, $0) }, uniquingKeysWith: { old, _ in old })
        return unique.values.filter {
            query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.group.localizedCaseInsensitiveContains(query)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
    func reset() {
        sourceName = "Blank draft"; sourceRoot = [:]; edits = [:]
        message = "Empty draft. Add staged entries to export."
    }
    func addCustom() {
        let s = customID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.range(of: #"^[a-zA-Z0-9_.-]{4,200}$"#, options: .regularExpression) != nil, s.contains(".") else {
            message = "Invalid identifier"; return
        }
        if !customTargets.contains(where: { $0.label == s }) && !Self.catalog.contains(where: { $0.label == s }) {
            customTargets.append(.init(group: "Custom", label: s, risk: "UNVERIFIED"))
        }
        customID = ""; message = "Identifier added to editor catalog; no iOS change"
    }
    func load(data: Data, filename: String) throws {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            throw NSError(domain: "KIZZIMO", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected a plist dictionary at its root"])
        }
        sourceRoot = root
        sourceName = filename
        edits = [:]
        message = "Imported \(root.count) source keys. Original file was not modified."
    }
    func displayState(_ label: String) -> String {
        if let override = edits[label] {
            switch override {
            case .disabled: return "STAGED: DISABLED"
            case .enabled: return "STAGED: ENABLED"
            case .remove: return "STAGED: REMOVE KEY"
            }
        }
        if let val = sourceRoot[label] as? Bool { return val ? "SOURCE: DISABLED" : "SOURCE: ENABLED" }
        return sourceRoot[label] == nil ? "SOURCE: ABSENT" : "SOURCE: NON-BOOLEAN"
    }
    func stage(_ choice: DraftOverride, label: String) {
        if choice == .disabled && label == "com.apple.thermalmonitord" {
            message = "Blocked disabling thermalmonitord"; return
        }
        edits[label] = choice
        message = "Staged \(label). iOS has not been modified."
    }
    private func composedRoot() -> [String: Any] {
        var result = sourceRoot
        for (key, value) in edits {
            switch value {
            case .disabled: result[key] = true
            case .enabled: result[key] = false
            case .remove: result.removeValue(forKey: key)
            }
        }
        return result
    }
    func exportXML() throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: composedRoot(), format: .xml, options: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KIZZIMO_Daemon_DRAFT.plist")
        try data.write(to: url, options: .atomic)
        return url
    }
    func exportJSON() throws -> URL {
        let ordered = edits.keys.sorted().map { key in
            ["label":key, "requested": edits[key] == .disabled ? "DISABLE" : edits[key] == .enabled ? "ENABLE" : "REMOVE"]
        }
        let report: [String: Any] = ["source":sourceName, "generated":ISO8601DateFormatter().string(from: Date()), "changes":ordered,
                   "note":"Offline draft only; no privileged on-device writes or CPU clock changes"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KIZZIMO_Daemon_Audit.json")
        try data.write(to: url, options: .atomic)
        return url
    }
}

struct ContentView: View {
    @StateObject private var engine = PowerEngine()
    @StateObject private var cadence = CadenceSampler()
    @StateObject private var daemons = DaemonDraft()
    @State private var showDaemonImporter = false
    @State private var touch: [Double] = []
    @State private var share: FileShare?
    @State private var confirmErase = false
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            powerTab.tabItem { Label("Power", systemImage: "bolt.fill") }
            cpuTab.tabItem { Label("CPU", systemImage: "cpu") }
            inputTab.tabItem { Label("Display / Touch", systemImage: "hand.tap") }
            daemonTab.tabItem { Label("Daemons", systemImage: "gearshape.2") }
            historyTab.tabItem { Label("Reports", systemImage: "chart.bar.xaxis") }
        }
        .tint(.teal)
        .onReceive(tick) { _ in engine.refresh() }
        .sheet(item: $share) { item in SharePanel(url: item.url) }
        .fileImporter(isPresented: $showDaemonImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try daemons.load(data: Data(contentsOf: url), filename: url.lastPathComponent)
            } catch { daemons.message = "Import failed: \(error.localizedDescription)" }
        }
        .confirmationDialog("Erase local benchmark records?", isPresented: $confirmErase) {
            Button("Erase records", role: .destructive) { engine.eraseRecords() }
        }
    }

    private var powerTab: some View {
        NavigationStack {
            Form {
                Section("LIVE SYSTEM STATE (READ-ONLY)") {
                    LabeledContent("Low Power Mode", value: engine.lowPower ? "On" : "Off")
                    LabeledContent("Thermal pressure", value: engine.thermal)
                    LabeledContent("Battery", value: engine.battery < 0 ? "Unavailable" : "\(engine.battery)%")
                    LabeledContent("Charging", value: engine.charging ? "Yes" : "No")
                    LabeledContent("Screen capability", value: "\(engine.displayMax) FPS maximum")
                    LabeledContent("Metal GPU", value: engine.gpu)
                    Text(engine.allocatedGPU).font(.caption).foregroundStyle(.secondary)
                    Button("Refresh now") { engine.refresh() }
                }
                Section("ACTUAL DEVICE WRITE: BRIGHTNESS") {
                    HStack {
                        Slider(value: Binding(get: { engine.brightness }, set: { engine.setBrightness($0) }), in: 0.05...1)
                        Text("\(Int(engine.brightness * 100))%")
                    }
                    Button("Restore brightness captured at launch") { engine.restoreBrightness() }
                    Text("Brightness may affect heat and power use, not CPU clock speed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("MAX PERFORMANCE CHECKLIST — MANUAL") {
                    Text("1. Settings → Battery: turn Low Power Mode off.")
                    Text("2. Compare Adaptive Power off versus on during normal use.")
                    Text("3. Accessibility → Motion: Limit Frame Rate off.")
                    Text("4. Keep Game Mode on for supported games.")
                    Text("5. Avoid excess heat; monitor battery and storage in Settings.")
                    Text("These settings aren't silently modified by this application.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("KIZZIMO Power")
        }
    }

    private var cpuTab: some View {
        NavigationStack {
            Form {
                Section("REAL QoS / ACTIVITY EXPERIMENTS") {
                    Text("Runs the SAME bounded computation under different QoS classes. Latency-critical adds a temporary ProcessInfo activity request. These hints apply only to this app; they do not force A19 clocks.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(PowerEngine.WorkMode.allCases) { mode in
                        Button(mode.rawValue) { engine.benchmark(mode) }.disabled(engine.running)
                    }
                    if engine.running { ProgressView(engine.progress) }
                    else { Text(engine.progress).font(.footnote).textSelection(.enabled) }
                }
                Section("MEASUREMENT GUIDE") {
                    Text("Run each mode at least 3 times, alternate their order, and compare results at similar temperature, power mode and brightness. Lower benchmark time is better for this synthetic workload, not proof of faster system-wide input.")
                        .font(.caption)
                    Text("A QoS request may have no measurable effect depending on iOS policy. Tests can briefly increase heat and battery consumption.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("CPU / QoS Lab")
        }
    }

    private var inputTab: some View {
        NavigationStack {
            Form {
                Section("DISPLAY-LINK CADENCE") {
                    Button(cadence.running ? "Running…" : "Measure display cadence") {
                        cadence.onResult = { engine.add("DisplayLink", $0) }
                        cadence.start()
                    }.disabled(cadence.running)
                    Text(cadence.summary).font(.footnote).textSelection(.enabled)
                }
                Section("TOUCH EVENT DELIVERY") {
                    Text("Tap in the square. We measure time between the UITouch event's timestamp and receipt by this app. This is NOT touch-to-photon delay or hardware polling rate.")
                        .font(.caption).foregroundStyle(.secondary)
                    TouchSurface { ms in
                        touch.append(ms)
                        if touch.count > 80 { touch.removeFirst() }
                    }
                    .frame(height: 170)
                    .overlay(Text("TAP HERE").font(.title2.bold()).allowsHitTesting(false))
                    if !touch.isEmpty {
                        Text("\(touch.count) samples · mean \(String(format: "%.2f", touch.reduce(0,+) / Double(touch.count))) ms")
                            .font(.footnote)
                    }
                    HStack {
                        Button("Save results") {
                            guard !touch.isEmpty else { return }
                            let sorted = touch.sorted()
                            let avg = touch.reduce(0, +) / Double(touch.count)
                            engine.add("Touch dispatch", String(format: "Mean %.2f ms, P95 %.2f ms (n=%d)", avg, sorted[Int(Double(sorted.count - 1)*0.95)], touch.count))
                        }.disabled(touch.isEmpty)
                        Button("Clear") { touch = [] }
                    }
                }
            }.navigationTitle("Input / Display")
        }
    }

    private var daemonTab: some View {
        NavigationStack {
            List {
                Section("OFFLINE CONFIGURATION — NOT LIVE DAEMONS") {
                    Text("An imported plist is edited in memory and exported separately. No system service is changed or stopped by this app.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Source: \(daemons.sourceName) · staged: \(daemons.edits.count)")
                        .font(.footnote)
                    HStack {
                        Button("Import plist") { showDaemonImporter = true }
                        Button("New blank") { daemons.reset() }
                    }
                    Button("Export staged XML plist") {
                        do { share = FileShare(url: try daemons.exportXML()) }
                        catch { daemons.message = "Export failed: \(error.localizedDescription)" }
                    }
                    Button("Export staged JSON audit") {
                        do { share = FileShare(url: try daemons.exportJSON()) }
                        catch { daemons.message = "Export failed: \(error.localizedDescription)" }
                    }
                    Button("Undo all staged edits", role: .destructive) { daemons.edits = [:]; daemons.message = "Draft cleared" }
                    Text(daemons.message).font(.caption).foregroundStyle(.secondary)
                }
                Section("ADD A CUSTOM LAUNCHD IDENTIFIER") {
                    TextField("com.apple.exampled", text: $daemons.customID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add to catalog") { daemons.addCustom() }
                }
                Section("DAEMON IDENTIFIERS — STAGED OVERRIDES") {
                    TextField("Search identifier or group", text: $daemons.query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    ForEach(daemons.filtered, id: \.label) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.label).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Text("\(item.group) · \(item.risk) · \(daemons.displayState(item.label))")
                                .font(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Button("Disable") { daemons.stage(.disabled, label: item.label) }
                                    .disabled(item.risk == "CRITICAL")
                                Button("Enable") { daemons.stage(.enabled, label: item.label) }
                                Button("Remove key") { daemons.stage(.remove, label: item.label) }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }.padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Daemon Draft Editor")
        }
    }

    private var historyTab: some View {
        NavigationStack {
            List {
                Section {
                    Button("Export JSON report") {
                        if let url = engine.export() { share = FileShare(url: url) }
                    }.disabled(engine.records.isEmpty)
                    Button("Delete results", role: .destructive) { confirmErase = true }
                        .disabled(engine.records.isEmpty)
                }
                Section("\(engine.records.count) SAVED TEST RESULTS") {
                    ForEach(engine.records) { r in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(r.test).font(.headline)
                            Text(r.result).font(.subheadline).textSelection(.enabled)
                            Text("\(r.when.formatted(date: .abbreviated, time: .shortened)) · LPM \(r.lowPower ? "ON" : "OFF") · \(r.thermal) · Battery \(r.battery)%")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            }.navigationTitle("Test History")
        }
    }
}

@main struct KIZZIMOPowerLabApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}