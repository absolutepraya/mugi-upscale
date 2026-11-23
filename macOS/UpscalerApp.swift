import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum UpscaleModel: String, CaseIterable, Identifiable {
    case drct, hat

    var id: Self { self }
    var name: String { self == .drct ? "DRCT-L" : "HAT-L" }
    var description: String {
        self == .drct ? "Clean photos and AI landscapes" : "Soft or compressed photos"
    }
}

struct Photo {
    let url: URL
    let preview: NSImage
    let width: Int
    let height: Int

    init(url: URL) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else {
            throw UpscaleError.unreadableImage
        }

        self.url = url
        self.preview = NSImage(cgImage: thumbnail, size: .zero)
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        self.width = (5...8).contains(orientation) ? rawHeight : rawWidth
        self.height = (5...8).contains(orientation) ? rawWidth : rawHeight
    }

    var dimensions: String { "\(width) × \(height)" }
}

enum UpscaleError: LocalizedError {
    case unreadableImage, missingSetup, failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "Choose a readable PNG, JPEG, WebP, or TIFF image."
        case .missingSetup: "The local upscaling engine is missing. Run ./setup.sh from the project folder."
        case .failed(let message): message
        }
    }
}

@MainActor
final class UpscaleJob: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var cancelling = false
    @Published private(set) var progress: Double?
    @Published private(set) var status = ""
    @Published private(set) var finishedElapsed: Duration?

    private var process: Process?
    private var directory: URL?
    private var startedAt: ContinuousClock.Instant?

    var elapsed: Duration {
        if let startedAt { return startedAt.duration(to: .now) }
        return finishedElapsed ?? .zero
    }

    deinit {
        if let process, process.isRunning { process.terminate() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func clearResult() {
        guard !running else { return }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        finishedElapsed = nil
    }

    func start(input: URL, model: UpscaleModel, completion: @escaping @MainActor @Sendable (Result<URL?, Error>) -> Void) throws {
        guard !running else { return }
        let project = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let python = project.appending(path: ".venv/bin/python")
        let script = project.appending(path: "upscale.py")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: python.path), files.fileExists(atPath: script.path) else {
            throw UpscaleError.missingSetup
        }

        clearResult()
        let directory = files.temporaryDirectory.appending(path: "4K-Upscaler-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        let output = directory.appending(path: "result.png")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = python
        process.arguments = ["-u", script.path, input.path, "-o", output.path, "--model", model.rawValue]
        process.currentDirectoryURL = project
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }

        self.directory = directory
        self.process = process
        startedAt = .now
        progress = nil
        status = "Preparing \(model.name)…"
        running = true

        DispatchQueue.global(qos: .userInitiated).async {
            var lastError: String?
            var remainder = Data()
            let reader = pipe.fileHandleForReading
            while true {
                let bytes = reader.availableData
                guard !bytes.isEmpty else { break }
                remainder.append(bytes)
                while let newline = remainder.firstIndex(of: 10) {
                    let line = String(decoding: remainder[..<newline], as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    remainder.removeSubrange(...newline)
                    if !line.isEmpty { lastError = line }
                    DispatchQueue.main.async { self.handle(line: line) }
                }
            }
            process.waitUntilExit()
            let diagnostic = lastError ?? "The upscaling engine exited before saving an image."
            let succeeded = process.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path)
            DispatchQueue.main.async {
                self.finish(output: output, succeeded: succeeded, diagnostic: diagnostic, completion: completion)
            }
        }
    }

    func cancel() {
        guard let process, process.isRunning, !cancelling else { return }
        cancelling = true
        status = "Cancelling…"
        process.terminate()
    }

    func shutDown() {
        cancel()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func handle(line: String) {
        guard !cancelling else { return }
        if line.hasPrefix("Tile ") {
            let counts = line.dropFirst("Tile ".count).split(separator: "/")
            if counts.count == 2, let done = Int(counts[0]), let total = Int(counts[1]),
               total > 0, (0...total).contains(done) {
                progress = Double(done) / Double(total)
                status = done < total ? "Upscaling · \(done) of \(total) tiles" : "Finishing PNG…"
            }
        } else if line.contains(" on mps") {
            status = "Upscaling on Metal…"
        }
    }

    private func finish(output: URL, succeeded: Bool, diagnostic: String,
                        completion: @MainActor (Result<URL?, Error>) -> Void) {
        let wasCancelled = cancelling
        let duration = elapsed
        startedAt = nil
        process = nil
        running = false
        cancelling = false
        progress = nil
        if wasCancelled || !succeeded { clearResult() }
        finishedElapsed = duration
        if wasCancelled {
            completion(.success(nil))
        } else if succeeded {
            completion(.success(output))
        } else {
            completion(.failure(UpscaleError.failed(diagnostic)))
        }
    }
}

@main
struct UpscalerApp: App {
    var body: some Scene {
        Window("4K Upscaler", id: "upscaler") {
            UpscalerView()
        }
        .defaultSize(width: 900, height: 600)
    }
}

@MainActor
private final class UpscalerWindowState: ObservableObject {
    @Published var source: Photo?
    @Published var result: Photo?
    @Published var model = UpscaleModel.drct
    @Published var errorMessage: String?
    @Published var activity: String?
    @Published var dragging = false
}

struct UpscalerView: View {
    private static let formats: [UTType] = [.png, .jpeg, .webP, .tiff]
    @StateObject private var job = UpscaleJob()
    @StateObject private var window = UpscalerWindowState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                preview(label: "Original", photo: window.source) {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 30, weight: .light))
                        Text("Drop an image here").font(.headline)
                        Button("Choose Image…", action: choose)
                    }
                }
                .overlay {
                    if window.dragging {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, urls.count == 1, !job.running else { return false }
                    select(url)
                    return true
                } isTargeted: { targeted in
                    window.dragging = targeted && !job.running
                }

                preview(label: "Upscaled", photo: window.result) {
                    VStack(spacing: 10) {
                        Image(systemName: "photo").font(.system(size: 30, weight: .light))
                        Text("Your preview will appear here").font(.headline)
                    }
                }
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Picker("Model", selection: $window.model) {
                        ForEach(UpscaleModel.allCases) { model in
                            Text(model.name).tag(model)
                        }
                    }
                    .fixedSize()
                    .disabled(job.running)
                    Text(window.model.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if job.running {
                        Button("Cancel", action: job.cancel)
                            .disabled(job.cancelling)
                    } else {
                        Button("Upscale", action: start)
                            .buttonStyle(.borderedProminent)
                            .disabled(window.source == nil)
                    }
                    Button("Save PNG…", action: save)
                        .keyboardShortcut("s")
                        .disabled(window.result == nil || job.running)
                }
                if job.running {
                    if let progress = job.progress {
                        ProgressView(value: progress)
                            .accessibilityLabel("Tile progress")
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                HStack(spacing: 12) {
                    Text(job.running ? job.status : window.activity ?? "3,840 px long edge · Original aspect ratio · PNG")
                        .lineLimit(1)
                    Spacer()
                    if job.running {
                        if let progress = job.progress {
                            Text("\(Int(progress * 100))%")
                                .accessibilityLabel("\(Int(progress * 100)) percent of tiles complete")
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            elapsedLabel(job.elapsed)
                        }
                    } else if let duration = job.finishedElapsed {
                        elapsedLabel(duration)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(minWidth: 690, minHeight: 440)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            job.shutDown()
        }
        .toolbar {
            Button(action: choose) {
                Label("Open Image…", systemImage: "folder")
            }
            .keyboardShortcut("o")
            .disabled(job.running)
        }
        .alert("4K Upscaler", isPresented: Binding(
            get: { window.errorMessage != nil },
            set: { if !$0 { window.errorMessage = nil } }
        )) {
            Button("OK") { window.errorMessage = nil }
        } message: {
            Text(window.errorMessage ?? "")
        }
    }

    private func elapsedLabel(_ duration: Duration) -> Text {
        let pattern: Duration.TimeFormatStyle.Pattern = duration >= .seconds(3600) ? .hourMinuteSecond : .minuteSecond
        return Text("Elapsed \(duration.formatted(.time(pattern: pattern)))")
    }

    private func preview<Placeholder: View>(
        label: String,
        photo: Photo?,
        @ViewBuilder placeholder: () -> Placeholder
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                if let photo {
                    Text(photo.dimensions).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                if let photo {
                    Image(nsImage: photo.preview)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                        .accessibilityLabel(label + " preview")
                } else {
                    placeholder().foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(photo.map { label == "Original" ? $0.url.lastPathComponent : "PNG" } ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.formats
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url { select(url) }
        }
    }

    private func select(_ url: URL) {
        guard !job.running else { return }
        do {
            let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
            guard url.isFileURL, Self.formats.contains(where: { type?.conforms(to: $0) == true }) else {
                throw UpscaleError.unreadableImage
            }
            window.source = try Photo(url: url)
            window.result = nil
            window.activity = nil
            job.clearResult()
        } catch {
            window.errorMessage = error.localizedDescription
        }
    }

    private func start() {
        guard let source = window.source else { return }
        window.result = nil
        window.activity = nil
        do {
            try job.start(input: source.url, model: window.model) { outcome in
                do {
                    if let url = try outcome.get() {
                        window.result = try Photo(url: url)
                        window.activity = "Ready to save"
                    } else {
                        window.activity = "Upscaling cancelled"
                    }
                } catch {
                    window.errorMessage = error.localizedDescription
                }
            }
        } catch {
            window.errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard let result = window.result, let source = window.source else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = source.url.deletingPathExtension().lastPathComponent + "-4k.png"
        panel.directoryURL = source.url.deletingLastPathComponent()
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                guard destination.resolvingSymlinksInPath() != source.url.resolvingSymlinksInPath() else {
                    throw UpscaleError.failed("Choose a different filename to keep the original image.")
                }
                try Data(contentsOf: result.url).write(to: destination, options: .atomic)
                window.activity = "Saved \(destination.lastPathComponent)"
            } catch {
                window.errorMessage = error.localizedDescription
            }
        }
    }
}
