import Darwin
import IOKit
import SwiftUI

// MARK: Settings

enum StatsValues: String, CaseIterable, Identifiable {
    case hidden, percent, usage

    var id: Self { self }
    var name: String {
        switch self {
        case .hidden: "None"
        case .percent: "Percentage"
        case .usage: "Used / total"
        }
    }
}

// MARK: Sampling

/// One reading of the three gauges. Fractions are 0...1.
struct SystemSnapshot: Equatable {
    var cpu = 0.0
    var cpuCores = ProcessInfo.processInfo.activeProcessorCount
    var memory = 0.0
    var memoryUsed: UInt64 = 0
    var memoryTotal = ProcessInfo.processInfo.physicalMemory
    var gpu = 0.0
    /// GPU memory is carved out of unified memory. Nil when the driver does not report it.
    var gpuMemoryUsed: UInt64?
}

@MainActor
final class SystemStats: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    private var previousTicks: (busy: UInt64, total: UInt64)?

    /// Samples once a second until the calling task is cancelled.
    func run() async {
        previousTicks = nil
        while !Task.isCancelled {
            sample()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func sample() {
        var next = SystemSnapshot()
        next.cpu = cpuLoad() ?? snapshot.cpu
        let memory = Self.memoryUsage()
        next.memoryUsed = memory.used
        next.memory = Double(memory.used) / Double(max(next.memoryTotal, 1))
        let gpu = Self.gpuUsage()
        next.gpu = gpu.load
        next.gpuMemoryUsed = gpu.memory
        if next != snapshot { snapshot = next }
    }

    /// Busy share of all cores since the previous call. Nil on the first call.
    private func cpuLoad() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let idle = UInt64(ticks.2)
        let total = UInt64(ticks.0) + UInt64(ticks.1) + idle + UInt64(ticks.3)
        defer { previousTicks = (total - idle, total) }
        guard let previous = previousTicks, total > previous.total else { return nil }
        let busy = (total - idle) - previous.busy
        return min(1, Double(busy) / Double(total - previous.total))
    }

    /// Memory in use as Activity Monitor counts it: app memory, wired, and compressed.
    private static func memoryUsage() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(max(sysconf(_SC_PAGESIZE), 4096))
        let app = UInt64(info.internal_page_count) &- UInt64(info.purgeable_count)
        let pages = app + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return (min(pages * page, total), total)
    }

    /// GPU utilization from the IOAccelerator registry entries. Needs no special permission.
    private static func gpuUsage() -> (load: Double, memory: UInt64?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
                == KERN_SUCCESS else { return (0, nil) }
        defer { IOObjectRelease(iterator) }
        var load = 0.0
        var memory: UInt64?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let stats = dictionary["PerformanceStatistics"] as? [String: Any] else { continue }
            if let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                load = max(load, min(max(value / 100, 0), 1))
            }
            if let value = (stats["In use system memory"] as? NSNumber)?.uint64Value {
                memory = max(memory ?? 0, value)
            }
        }
        return (load, memory)
    }
}

// MARK: View

/// CPU, memory, and GPU gauges for the control bar. Settings choose the value text.
struct SystemMonitor: View {
    let values: StatsValues
    @StateObject private var stats = SystemStats()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Gauge: Identifiable {
        let id: String
        let fraction: Double
        let percent: String
        let usage: String
        let detail: String
    }

    private var readings: [Gauge] {
        let s = stats.snapshot
        let busyCores = s.cpu * Double(s.cpuCores)
        return [
            Gauge(id: "CPU", fraction: s.cpu,
                  percent: Self.percent(s.cpu),
                  usage: "\(busyCores.formatted(.number.precision(.fractionLength(1))))/\(s.cpuCores)",
                  detail: "\(Self.percent(s.cpu)) of \(s.cpuCores) cores busy"),
            Gauge(id: "Memory", fraction: s.memory,
                  percent: Self.percent(s.memory),
                  usage: "\(Self.gigabytes(s.memoryUsed))/\(Self.gigabytes(s.memoryTotal)) GB",
                  detail: "\(Self.gigabytes(s.memoryUsed)) of \(Self.gigabytes(s.memoryTotal)) GB in use"),
            gpuGauge(s),
        ]
    }

    private func gpuGauge(_ s: SystemSnapshot) -> Gauge {
        // The GPU shares unified memory, so its "used / total" is the memory it holds.
        let usage = s.gpuMemoryUsed.map { "\(Self.gigabytes($0))/\(Self.gigabytes(s.memoryTotal)) GB" }
            ?? Self.percent(s.gpu)
        let memory = s.gpuMemoryUsed.map { ", holding \(Self.gigabytes($0)) of \(Self.gigabytes(s.memoryTotal)) GB" } ?? ""
        return Gauge(id: "GPU", fraction: s.gpu,
                     percent: Self.percent(s.gpu), usage: usage,
                     detail: "\(Self.percent(s.gpu)) busy\(memory)")
    }

    var body: some View {
        gauges
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: stats.snapshot)
            .task { await stats.run() }
    }

    private func text(_ gauge: Gauge) -> String? {
        switch values {
        case .hidden: nil
        case .percent: gauge.percent
        case .usage: gauge.usage
        }
    }

    private var gauges: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(readings) { gauge in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(gauge.id == "Memory" ? "MEM" : gauge.id)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        if let value = text(gauge) {
                            Spacer(minLength: 2)
                            Text(value).lineLimit(1).fixedSize()
                        }
                    }
                    .font(.caption2.weight(.medium).monospacedDigit())
                    track(gauge.fraction)
                        .frame(height: 6)
                }
                .frame(minWidth: values == .usage ? 84 : 62)
                .help(gauge.detail)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(gauge.id)
                .accessibilityValue(gauge.detail)
            }
        }
    }

    /// A capsule track with a capsule fill that grows from the left.
    private func track(_ fraction: Double) -> some View {
        Capsule()
            .fill(Color.secondary.opacity(0.22))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(geometry.size.height, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return value >= 100 ? value.formatted(.number.precision(.fractionLength(0)))
            : value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
