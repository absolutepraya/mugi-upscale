import AppKit
import SwiftUI

struct EngineLocation {
    let root: URL
    private let packaged: Bool

    init(bundle: Bundle = .main) {
        let bundledEngine = bundle.resourceURL?.appending(path: "engine")
        if let bundledEngine, FileManager.default.fileExists(atPath: bundledEngine.appending(path: "upscale.py").path) {
            root = bundledEngine
            packaged = true
        } else {
            root = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            packaged = false
        }
    }

    static var seedCache: URL {
        // Isolate the caches of local test builds with a different bundle identifier.
        let identifier = Bundle.main.bundleIdentifier ?? "dev.abhipraya.local-upscaler"
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches")
            .appending(path: identifier)
            .appending(path: "SeedVR2")
    }

    func process(script name: String, arguments: [String], pipe: Pipe) throws -> Process {
        let python = root.appending(path: packaged ? "python/bin/python3.12" : ".venv/bin/python")
        let script = root.appending(path: name)
        let files = FileManager.default
        guard files.isExecutableFile(atPath: python.path), files.fileExists(atPath: script.path) else {
            throw UpscaleError.missingSetup
        }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", "-B", "-u", script.path] + arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["MUGI_SEEDVR2_CACHE"] = Self.seedCache.path
        environment["MUGI_ENGINE_EVENTS"] = "1"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        return process
    }
}

// Drain both output streams before waiting for the child, including a final partial line.
func observeEngine(_ process: Process, pipe: Pipe,
                   line: @escaping @MainActor @Sendable (String) -> Void,
                   finished: @escaping @MainActor @Sendable (Bool, String?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        var lastLine: String?
        var remainder = Data()
        let reader = pipe.fileHandleForReading
        while true {
            let bytes = reader.availableData
            guard !bytes.isEmpty else { break }
            remainder.append(bytes)
            while let newline = remainder.firstIndex(of: 10) {
                let message = String(decoding: remainder[..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                remainder.removeSubrange(...newline)
                if !message.isEmpty { lastLine = message }
                DispatchQueue.main.async { line(message) }
            }
        }
        let tail = String(decoding: remainder, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { lastLine = tail }
        process.waitUntilExit()
        let succeeded = process.terminationStatus == 0
        let diagnostic = lastLine
        DispatchQueue.main.async { finished(succeeded, diagnostic) }
    }
}

@MainActor
final class ModelLibrary: ObservableObject {
    enum Operation: String {
        case download, delete
    }

    struct Transfer {
        let received: Int64
        let total: Int64
        let bytesPerSecond: Int64

        var fraction: Double { min(1, Double(received) / Double(total)) }
        var percent: String { "\(Int(fraction * 100))%" }
    }

    private struct Weight: Decodable {
        let name: String
        let bytes: Int64
    }

    @Published private(set) var seedInstalled = false
    @Published private(set) var seedHasFiles = false
    @Published private(set) var operation: Operation?
    @Published private(set) var pausing = false
    @Published private(set) var transfer: Transfer?
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var localFiles: [UpscaleModel: [URL]] = [:]
    private var process: Process?

    var canUseSeed: Bool { seedInstalled && operation == nil }
    var downloadTitle: String { seedHasFiles && !seedInstalled ? "Resume Download" : "Download" }

    deinit {
        if let process, process.isRunning { process.terminate() }
    }

    func refresh() {
        let engine = EngineLocation().root
        let directory = engine.appending(path: "models")
        let manifest = engine.appending(path: "seedvr2-model.json")
        let weights = (try? JSONDecoder().decode([Weight].self, from: Data(contentsOf: manifest))) ?? []
        let cache = EngineLocation.seedCache
        let candidates = weights.flatMap { weight in
            [cache.appending(path: weight.name), cache.appending(path: weight.name + ".download")]
        }
        let files = FileManager.default
        let found = candidates.filter { files.fileExists(atPath: $0.path) }
        localFiles = [
            .drct: [directory.appending(path: "4xNomos2_hq_drct-l.safetensors")].filter { files.fileExists(atPath: $0.path) },
            .hat: [directory.appending(path: "4xNomos8kSCHAT-L.safetensors")].filter { files.fileExists(atPath: $0.path) },
            .anime: [directory.appending(path: "RealESRGAN_x4plus_anime_6B.pth")].filter { files.fileExists(atPath: $0.path) },
            .seedvr2: found
        ]
        seedHasFiles = !found.isEmpty
        seedInstalled = !weights.isEmpty && weights.allSatisfy { weight in
            let url = cache.appending(path: weight.name)
            let resource = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return resource?.isRegularFile == true && resource?.fileSize.map(Int64.init) == weight.bytes
        }
    }

    func reveal(_ model: UpscaleModel) {
        refresh()
        guard let urls = localFiles[model], !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func start(_ action: Operation) {
        guard operation == nil else { return }
        error = nil
        let pipe = Pipe()
        do {
            let process = try EngineLocation().process(script: "seedvr2.py", arguments: [action.rawValue], pipe: pipe)
            try process.run()
            self.process = process
            operation = action
            transfer = nil
            pausing = false
            status = action == .download ? "Preparing download…" : "Removing SeedVR2…"
            observeEngine(process, pipe: pipe) { message in
                self.handle(message)
            } finished: { succeeded, diagnostic in
                let paused = self.pausing
                self.process = nil
                self.operation = nil
                self.transfer = nil
                self.pausing = false
                self.refresh()
                if !succeeded && !paused {
                    self.error = diagnostic ?? (action == .download ? "Could not download SeedVR2." : "Could not remove SeedVR2.")
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func pause() {
        guard operation == .download, let process, process.isRunning, !pausing else { return }
        pausing = true
        status = "Pausing download…"
        process.terminate()
    }

    func shutDown() {
        if let process, process.isRunning { process.terminate() }
    }

    private func handle(_ message: String) {
        guard !pausing else { return }
        if message.hasPrefix("Status ") {
            status = String(message.dropFirst("Status ".count))
        } else if message.hasPrefix("Download ") {
            let fields = message.split(separator: " ")
            guard fields.count == 4, let received = Int64(fields[1]), let total = Int64(fields[2]),
                  let speed = Int64(fields[3]), total > 0, received >= 0, speed >= 0 else { return }
            transfer = Transfer(received: received, total: total, bytesPerSecond: speed)
        }
    }
}

struct SeedDownloadStatus: View {
    @EnvironmentObject private var library: ModelLibrary
    var showsModelName = false

    var body: some View {
        HStack(spacing: 8) {
            if let transfer = library.transfer {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: transfer.fraction)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
                if showsModelName { Text("SeedVR2") }
                Text(transfer.percent)
                if transfer.bytesPerSecond > 0 && !library.pausing {
                    Text("\(ByteCountFormatter.string(fromByteCount: transfer.bytesPerSecond, countStyle: .file))/s")
                } else {
                    Text(library.status).lineLimit(1)
                }
            } else {
                ProgressView().controlSize(.small)
                Text(library.status).lineLimit(1)
            }
            Button(action: library.pause) {
                Image(systemName: "pause.circle")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(library.pausing)
            .help("Pause download")
            .accessibilityLabel("Pause download")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}
