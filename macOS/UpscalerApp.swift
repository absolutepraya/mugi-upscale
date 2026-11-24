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
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(rawWidth, rawHeight)
              ] as CFDictionary) else {
            throw UpscaleError.unreadableImage
        }

        self.url = url
        self.preview = NSImage(cgImage: image, size: .zero)
        self.width = image.width
        self.height = image.height
    }

    var dimensions: String { "\(width) × \(height)" }
    var pixelSize: CGSize { CGSize(width: width, height: height) }
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

    func clearResults() {
        guard !running else { return }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        finishedElapsed = nil
    }

    func discardOutput(_ output: URL) {
        try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
    }

    func start(input: URL, model: UpscaleModel, startedAt: ContinuousClock.Instant,
               completion: @escaping @MainActor @Sendable (Result<URL?, Error>) -> Void) throws {
        guard !running else { return }
        let bundle = Bundle.main.bundleURL
        let bundledEngine = bundle.appending(path: "Contents/Resources/engine")
        let bundledScript = bundledEngine.appending(path: "upscale.py")
        let files = FileManager.default
        let packaged = files.fileExists(atPath: bundledScript.path)
        let engine = packaged ? bundledEngine : bundle.deletingLastPathComponent().deletingLastPathComponent()
        let python = packaged ? bundledEngine.appending(path: "python/bin/python3.12")
                              : engine.appending(path: ".venv/bin/python")
        let script = engine.appending(path: "upscale.py")
        guard files.isExecutableFile(atPath: python.path), files.fileExists(atPath: script.path) else {
            throw UpscaleError.missingSetup
        }

        let directory = self.directory ?? files.temporaryDirectory.appending(path: "Mugi-\(UUID().uuidString)")
        let renderDirectory = directory.appending(path: UUID().uuidString)
        try files.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
        self.directory = directory
        let output = renderDirectory.appending(path: "result.png")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = python
        process.arguments = (packaged ? ["-I", "-B"] : []) + ["-u", script.path, input.path, "-o", output.path, "--model", model.rawValue]
        process.currentDirectoryURL = engine
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            discardOutput(output)
            throw error
        }

        self.process = process
        self.startedAt = startedAt
        finishedElapsed = nil
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
                    DispatchQueue.main.async { self.handle(line: line, model: model) }
                }
            }
            process.waitUntilExit()
            let diagnostic = lastError ?? "The upscaling engine exited before saving an image."
            let succeeded = process.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path)
            DispatchQueue.main.async {
                self.finish(output: output, succeeded: succeeded,
                            diagnostic: diagnostic, completion: completion)
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

    private func handle(line: String, model: UpscaleModel) {
        guard !cancelling else { return }
        if line.hasPrefix("Tile ") {
            let counts = line.dropFirst("Tile ".count).split(separator: "/")
            if counts.count == 2, let done = Int(counts[0]), let total = Int(counts[1]),
               total > 0, (0...total).contains(done) {
                progress = Double(done) / Double(total)
                status = done < total ? "\(model.name) · \(done) of \(total) tiles" : "Finishing PNG…"
            }
        } else if line.contains(" on mps") {
            status = "Upscaling with \(model.name) on Metal…"
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
        if wasCancelled || !succeeded { discardOutput(output) }
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
        Window("Mugi", id: "upscaler") {
            UpscalerView()
        }
        .defaultSize(width: 900, height: 600)
    }
}

@MainActor
private final class UpscalerWindowState: ObservableObject {
    @Published var source: Photo?
    @Published var results: [UpscaleModel: Photo] = [:]
    @Published var model = UpscaleModel.drct
    @Published var comparingModels = false
    @Published var zoom = PreviewZoom.fit
    @Published var pan = ImageViewport.center
    @Published var errorMessage: String?
    @Published var activity: String?
    @Published var dragging = false

    var displayedModel: UpscaleModel? {
        if results[model] != nil { return model }
        return UpscaleModel.allCases.first { results[$0] != nil }
    }
}

private enum PreviewZoom: Hashable {
    case fit, actualPixels
}

struct UpscalerView: View {
    private static let formats: [UTType] = [.png, .jpeg, .webP, .tiff]
    @StateObject private var job = UpscaleJob()
    @StateObject private var window = UpscalerWindowState()
    @Environment(\.displayScale) private var displayScale
    @GestureState private var dragTranslation = CGSize.zero

    var body: some View {
        VStack(spacing: 0) {
            comparisonWorkspace
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
                        Button("Upscale") { render([window.model]) }
                            .buttonStyle(.borderedProminent)
                            .disabled(window.source == nil)
                    }
                    if window.comparingModels {
                        Menu("Save PNG…") {
                            ForEach(UpscaleModel.allCases) { model in
                                Button("Save \(model.name)…") { save(model: model) }
                            }
                        }
                        .fixedSize()
                        .disabled(job.running)
                    } else {
                        Button("Save PNG…") {
                            if let model = window.displayedModel { save(model: model) }
                        }
                        .keyboardShortcut("s")
                        .disabled(window.displayedModel == nil || job.running)
                    }
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
        .alert("Mugi", isPresented: Binding(
            get: { window.errorMessage != nil },
            set: { if !$0 { window.errorMessage = nil } }
        )) {
            Button("OK") { window.errorMessage = nil }
        } message: {
            Text(window.errorMessage ?? "")
        }
    }

    private var comparisonWorkspace: some View {
        let result = window.displayedModel.flatMap { window.results[$0] }
        let reference = result?.pixelSize ?? window.source?.pixelSize
        let rightModel = window.comparingModels ? UpscaleModel.hat : window.displayedModel
        let spacing: CGFloat = 20

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Zoom", selection: $window.zoom) {
                    Text("Fit").tag(PreviewZoom.fit)
                    Text("1:1").tag(PreviewZoom.actualPixels)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(window.source == nil)
                .help("At 1:1, drag either image to pan. Both views stay aligned.")
                Spacer()
                Button(window.comparingModels ? "Show Original" : "Compare Models", action: toggleComparison)
                    .disabled(window.source == nil || job.running)
                    .help(window.comparingModels
                          ? "View the original alongside the selected model output."
                          : "Render any missing model outputs and compare them side by side.")
            }
            GeometryReader { geometry in
                let paneWidth = max(0, (geometry.size.width - spacing) / 2)
                HStack(alignment: .top, spacing: spacing) {
                    preview(label: window.comparingModels ? UpscaleModel.drct.name : "Original",
                            photo: window.comparingModels ? window.results[.drct] : window.source,
                            reference: reference) {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 30, weight: .light))
                            Text("Drop an image here").font(.headline)
                            Button("Choose Image…", action: choose)
                        }
                    }
                    .frame(width: paneWidth)
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

                    preview(label: rightModel?.name ?? "Upscaled",
                            photo: rightModel.flatMap { window.results[$0] },
                            reference: reference) {
                        VStack(spacing: 10) {
                            Image(systemName: "photo").font(.system(size: 30, weight: .light))
                            Text("Your preview will appear here").font(.headline)
                        }
                    }
                    .frame(width: paneWidth)
                }
            }
        }
    }

    private func elapsedLabel(_ duration: Duration) -> Text {
        let pattern: Duration.TimeFormatStyle.Pattern = duration >= .seconds(3600) ? .hourMinuteSecond : .minuteSecond
        return Text("Elapsed \(duration.formatted(.time(pattern: pattern)))")
    }

    private func preview<Placeholder: View>(
        label: String,
        photo: Photo?,
        reference: CGSize?,
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
                if let photo, let reference {
                    GeometryReader { geometry in
                        previewImage(photo, label: label, reference: reference, size: geometry.size)
                    }
                } else {
                    placeholder().foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(photo.map { label == "Original" ? $0.url.lastPathComponent : "PNG" } ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func previewImage(_ photo: Photo, label: String, reference: CGSize, size: CGSize) -> some View {
        let actualPixels = window.zoom == .actualPixels
        let viewport = ImageViewport(size: size, pixels: reference, displayScale: displayScale, actualPixels: actualPixels)
        let focus = viewport.panned(from: window.pan, by: dragTranslation)
        return Image(nsImage: photo.preview)
            .resizable()
            .interpolation(actualPixels && photo.pixelSize == reference ? .none : .high)
            .frame(width: viewport.imageSize.width, height: viewport.imageSize.height)
            .position(viewport.imageCenter(at: focus))
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($dragTranslation) { value, translation, _ in translation = value.translation }
                    .onEnded { value in window.pan = viewport.panned(from: window.pan, by: value.translation) },
                including: viewport.canPan ? .all : .none
            )
            .accessibilityLabel(label + " preview")
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
            window.results = [:]
            window.comparingModels = false
            window.zoom = .fit
            window.pan = ImageViewport.center
            window.activity = nil
            job.clearResults()
        } catch {
            window.errorMessage = error.localizedDescription
        }
    }

    private func toggleComparison() {
        if window.comparingModels {
            window.comparingModels = false
            return
        }
        let missing = UpscaleModel.allCases.filter { window.results[$0] == nil }
        render(missing[...], compareWhenReady: true)
    }

    private func render(_ models: ArraySlice<UpscaleModel>, compareWhenReady: Bool = false,
                        startedAt: ContinuousClock.Instant = .now) {
        guard let source = window.source, !job.running else { return }
        guard let model = models.first else {
            window.comparingModels = compareWhenReady
            return
        }
        window.activity = nil
        do {
            try job.start(input: source.url, model: model, startedAt: startedAt) { outcome in
                do {
                    guard let url = try outcome.get() else {
                        window.activity = "Upscaling cancelled"
                        return
                    }
                    do {
                        let photo = try Photo(url: url)
                        if let previous = window.results.updateValue(photo, forKey: model) {
                            job.discardOutput(previous.url)
                        }
                    } catch {
                        job.discardOutput(url)
                        throw error
                    }
                    if models.count > 1 {
                        render(models.dropFirst(), compareWhenReady: compareWhenReady, startedAt: startedAt)
                    } else {
                        if compareWhenReady { window.comparingModels = true }
                        window.activity = "Ready to save"
                    }
                } catch {
                    window.errorMessage = error.localizedDescription
                }
            }
        } catch {
            window.errorMessage = error.localizedDescription
        }
    }

    private func save(model: UpscaleModel) {
        guard let result = window.results[model], let source = window.source else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let stem = source.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(stem)-\(model.rawValue)-4k.png"
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
