import SwiftUI
import UIKit
import Foundation
import Metal

@main
struct PulseLabApp: App {
    @StateObject private var engine = PulseEngine()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            PulseView().environmentObject(engine)
                .onChange(of: scenePhase) { phase in
                    if phase != .active { engine.stop(message: "Stopped when app left foreground") }
                }
        }
    }
}

enum PulsePreset: String, CaseIterable, Identifiable {
    case balanced = "Balanced", fast = "Fast", extreme = "Extreme", custom = "Custom"
    var id: String { rawValue }
}
struct PulseConfig {
    let cadence: Int
    let cpuUs: Int
    let gpuSize: Int
    let gpuEvery: Int
    let fileEvery: Int
    let cpu: Bool
    let gpu: Bool
    let storage: Bool
    let write: Bool
}
struct PulseCounts {
    var cpu = 0
    var gpu = 0
    var file = 0
    var failures = 0
    var cpuMs = 0.0
    var gpuMs = 0.0
    var fileMs = 0.0
    var error = ""
}

final class PulseEngine: ObservableObject {
    @Published var preset = PulsePreset.balanced
    @Published var cadence = 40.0
    @Published var cpuUs = 100.0
    @Published var gpuSize = 2048.0
    @Published var gpuEvery = 5
    @Published var fileEvery = 1500.0
    @Published var cpu = true
    @Published var gpu = true
    @Published var storage = true
    @Published var write = false
    @Published var keepScreen = true
    @Published var duration = 15
    @Published private(set) var running = false
    @Published private(set) var status = "Ready"
    @Published private(set) var counts = PulseCounts()
    @Published private(set) var elapsed = 0
    @Published private(set) var thermal = "Nominal"
    @Published private(set) var battery = "—"

    private let queue = DispatchQueue(label: "org.pulselab.worker", qos: .userInitiated)
    private var source: DispatchSourceTimer?
    private var refreshTimer: Timer?
    private var started: TimeInterval = 0
    private var workerCounts = PulseCounts() // only read/write on queue
    private var tick = 0                     // worker queue only
    private var lastFileNs: UInt64 = 0       // worker queue only
    private var accumulator: UInt64 = 0xC0FFEE
    private var metal: MetalPulse?
    private var disk: DiskPulse?

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        environment()
    }

    func setPreset(_ p: PulsePreset) {
        guard !running else { return }
        preset = p
        switch p {
        case .balanced:
            cadence = 40; cpuUs = 100; gpuSize = 2048
            gpuEvery = 5; fileEvery = 1500
        case .fast:
            cadence = 15; cpuUs = 250; gpuSize = 4096
            gpuEvery = 3; fileEvery = 1000
        case .extreme:
            cadence = 5; cpuUs = 450; gpuSize = 8192
            gpuEvery = 2; fileEvery = 500
        case .custom:
            break
        }
    }

    func start() {
        guard !running else { return }
        if ProcessInfo.processInfo.thermalState == .critical {
            status = "iOS reports critical temperature — cannot start"
            return
        }
        let config = PulseConfig(cadence: max(5, Int(cadence)),
                                 cpuUs: max(0, Int(cpuUs)),
                                 gpuSize: max(1024, Int(gpuSize)),
                                 gpuEvery: max(1, gpuEvery),
                                 fileEvery: max(250, Int(fileEvery)),
                                 cpu: cpu, gpu: gpu, storage: storage, write: write)
        guard config.cpu || config.gpu || config.storage else {
            status = "Enable at least one workload"
            return
        }
        counts = PulseCounts()
        elapsed = 0
        started = ProcessInfo.processInfo.systemUptime
        running = true
        status = "Running in foreground (no hardware clock override)"
        UIApplication.shared.isIdleTimerDisabled = keepScreen
        queue.async { [weak self] in
            self?.workerCounts = PulseCounts()
            self?.tick = 0
            self?.lastFileNs = 0
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(config.cadence), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.work(config) }
        source = timer
        timer.resume()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.snapshot()
        }
    }

    func stop(message: String = "Stopped") {
        guard running else { return }
        running = false
        source?.cancel()
        source = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        status = message
        environment()
    }

    private func work(_ c: PulseConfig) {
        tick += 1
        let heat = ProcessInfo.processInfo.thermalState
        if heat == .critical {
            DispatchQueue.main.async { [weak self] in
                self?.stop(message: "Stopped by critical thermal pressure")
            }
            return
        }
        let divisor = heat == .serious ? 4 : (heat == .fair ? 2 : 1)
        if tick % divisor != 0 { return }
        if c.cpu && c.cpuUs > 0 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let end = t0 + UInt64(c.cpuUs) * 1000
            var x = accumulator
            repeat {
                for _ in 0..<32 { x = x &* 2862933555777941757 &+ 3037000493 }
            } while DispatchTime.now().uptimeNanoseconds < end
            accumulator = x
            workerCounts.cpu += 1
            workerCounts.cpuMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
        }
        if c.gpu && tick % c.gpuEvery == 0 {
            if metal == nil { metal = MetalPulse() }
            if let ms = metal?.pulse(c.gpuSize) {
                workerCounts.gpu += 1
                workerCounts.gpuMs = ms
            } else {
                workerCounts.failures += 1
                workerCounts.error = "Metal command failed or unavailable"
            }
        }
        if c.storage {
            let now = DispatchTime.now().uptimeNanoseconds
            if lastFileNs == 0 || now - lastFileNs >= UInt64(c.fileEvery) * 1_000_000 {
                lastFileNs = now
                do {
                    if disk == nil { disk = try DiskPulse() }
                    if let ms = try disk?.pulse(write: c.write) {
                        workerCounts.file += 1
                        workerCounts.fileMs = ms
                    }
                } catch {
                    workerCounts.failures += 1
                    workerCounts.error = "Storage: \(error.localizedDescription)"
                }
            }
        }
    }

    private func snapshot() {
        guard running else { return }
        elapsed = max(0, Int(ProcessInfo.processInfo.systemUptime - started))
        environment()
        if duration > 0 && elapsed >= duration * 60 {
            stop(message: "Session duration reached")
            return
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            let next = self.workerCounts
            DispatchQueue.main.async { [weak self] in
                if self?.running == true { self?.counts = next }
            }
        }
    }

    private func environment() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair (½ rate)"
        case .serious: thermal = "Serious (¼ rate)"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }
        let level = UIDevice.current.batteryLevel
        battery = level < 0 ? "Unavailable" : "\(Int(level * 100))%"
    }
}

private final class MetalPulse {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let q = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary(),
              let fn = lib.makeFunction(name: "pulse_compute"),
              let p = try? device.makeComputePipelineState(function: fn),
              let b = device.makeBuffer(length: 32768 * MemoryLayout<Float>.stride,
                                        options: .storageModeShared) else { return nil }
        queue = q; pipeline = p; buffer = b
        let pointer = b.contents().bindMemory(to: Float.self, capacity: 32768)
        for i in 0..<32768 { pointer[i] = Float(i % 97) / 97 }
    }
    func pulse(_ amount: Int) -> Double? {
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        let count = min(max(amount, 1024), 32768)
        let threads = max(1, min(pipeline.threadExecutionWidth, count))
        let start = DispatchTime.now().uptimeNanoseconds
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(buffer, offset: 0, index: 0)
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status != .completed { return nil }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }
}

private final class DiskPulse {
    private let url: URL
    private let block = Data(repeating: 0x6A, count: 4096)
    init() throws {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = base.appendingPathComponent("pulse_owned_test.bin")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data(repeating: 0x3C, count: 65536).write(to: url, options: .atomic)
        }
    }
    func pulse(write: Bool) throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        let reader = try FileHandle(forReadingFrom: url)
        _ = try reader.read(upToCount: 4096)
        try reader.close()
        if write {
            let writer = try FileHandle(forWritingTo: url)
            try writer.seek(toOffset: 0)
            try writer.write(contentsOf: block)
            try writer.close()
        }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }
}

struct PulseView: View {
    @EnvironmentObject private var engine: PulseEngine
    private let grid = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("CPU • Metal GPU • Storage")
                        .font(.title3.bold())
                    Text("Experimental foreground hardware workload laboratory")
                        .font(.subheadline).foregroundStyle(.secondary)
                    GroupBox("Profiles") {
                        LazyVGrid(columns: grid, spacing: 8) {
                            ForEach(PulsePreset.allCases) { p in
                                Button(p.rawValue) { engine.setPreset(p) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(engine.preset == p ? .blue : .gray)
                                    .disabled(engine.running)
                            }
                        }
                    }
                    GroupBox("Engines") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("CPU micro-bursts", isOn: $engine.cpu)
                            Toggle("Metal GPU compute", isOn: $engine.gpu)
                            Toggle("App-sandbox storage I/O", isOn: $engine.storage)
                            Toggle("Allow 4 KiB file writes", isOn: $engine.write)
                                .disabled(!engine.storage)
                            Toggle("Keep screen awake", isOn: $engine.keepScreen)
                        }.disabled(engine.running)
                    }
                    GroupBox("Cadence & intensity") {
                        VStack(spacing: 10) {
                            labSlider("Polling cadence", value: $engine.cadence,
                                      range: 5...100, step: 5, suffix: "ms")
                            labSlider("CPU work per tick", value: $engine.cpuUs,
                                      range: 0...1000, step: 50, suffix: "µs")
                            labSlider("Metal threads", value: $engine.gpuSize,
                                      range: 1024...32768, step: 1024, suffix: "")
                            Stepper("GPU every \(engine.gpuEvery) tick(s)",
                                    value: $engine.gpuEvery, in: 1...20)
                            labSlider("Storage interval", value: $engine.fileEvery,
                                      range: 250...3000, step: 250, suffix: "ms")
                        }.disabled(engine.running)
                    }
                    GroupBox("Session") {
                        Picker("Duration", selection: $engine.duration) {
                            Text("15 min").tag(15)
                            Text("1 hour").tag(60)
                            Text("24 hours").tag(1440)
                            Text("Manual").tag(0)
                        }.pickerStyle(.menu).disabled(engine.running)
                    }
                    Button {
                        if engine.running { engine.stop() } else { engine.start() }
                    } label: {
                        Label(engine.running ? "Stop engine" : "Start engine",
                              systemImage: engine.running ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity).padding(8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(engine.running ? .red : .blue)
                    GroupBox("Live results") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(engine.status).font(.footnote)
                            HStack {
                                result("Time", "\(engine.elapsed)s")
                                result("Thermal", engine.thermal)
                                result("Battery", engine.battery)
                            }
                            Divider()
                            HStack {
                                result("CPU bursts", "\(engine.counts.cpu)")
                                result("GPU jobs", "\(engine.counts.gpu)")
                                result("File ops", "\(engine.counts.file)")
                            }
                            HStack {
                                result("CPU duration", display(engine.counts.cpuMs))
                                result("GPU completion", display(engine.counts.gpuMs))
                                result("File duration", display(engine.counts.fileMs))
                            }
                            if engine.counts.failures > 0 {
                                Text("Errors: \(engine.counts.failures) • \(engine.counts.error)")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                        }
                    }
                    Text("This app performs real bounded work only while foregrounded. It does not directly poll CPU/GPU/NVMe hardware, change power-state residency, lock clocks or run after you switch apps. Reads may be served from cache. Increased temperature can worsen latency; workload reduces automatically as iOS heats up.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("PulseLab")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func display(_ ms: Double) -> String {
        String(format: "%.3f ms", ms)
    }
    private func result(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.bold()).lineLimit(2).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func labSlider(_ label: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double,
                           suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = $0; engine.setPreset(.custom) }
            ), in: range, step: step)
        }
    }
}
