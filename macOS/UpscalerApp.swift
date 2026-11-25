import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum UpscaleModel: String, CaseIterable, Identifiable {
    case seedvr2, drct, hat

    static let defaultChoice: Self = .seedvr2

    var id: Self { self }
    var name: String {
        switch self {
        case .drct: "DRCT-L"
        case .hat: "HAT-L"
        case .seedvr2: "SeedVR2"
        }
    }

    var description: String {
        switch self {
        case .drct: "Enlarges clean images with subtle changes to detail."
        case .hat: "Sharpens soft images and cleans up compression artifacts."
        case .seedvr2: "Rebuilds textures in AI images and can change fine shapes and color."
        }
    }

    var sourceFidelity: ModelLevel {
        switch self {
        case .drct: .high
        case .hat, .seedvr2: .moderate
        }
    }

    var naturalTexture: ModelLevel {
        switch self {
        case .drct: .limited
        case .hat: .moderate
        case .seedvr2: .high
        }
    }
}

enum ModelLevel: Int {
    case limited = 1, moderate, high

    var label: String {
        switch self {
        case .limited: "Limited"
        case .moderate: "Moderate"
        case .high: "High"
        }
    }
}

private struct ModelBars: View {
    let model: UpscaleModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            bar("Source fidelity", level: model.sourceFidelity,
                explanation: "How closely the model keeps the shapes, colors, and text from your original image.")
            bar("Natural texture", level: model.naturalTexture,
                explanation: "How realistic fine details like hair, skin, or fabric tend to look after upscaling a photo.")
        }
        .frame(maxWidth: 350)
    }

    private func bar(_ title: String, level: ModelLevel, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(title).accessibilityLabel("\(title), \(level.label)")
                MetricInfoButton(title: title, explanation: explanation)
                Spacer(minLength: 4)
                Text(level.label)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.caption)
            HStack(spacing: 3) {
                ForEach(1...3, id: \.self) { segment in
                    Capsule()
                        .fill(segment <= level.rawValue ? Color.accentColor : Color.secondary.opacity(0.18))
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

private struct MetricInfoButton: View {
    let title: String
    let explanation: String
    @State private var showingExplanation = false

    var body: some View {
        Button { showingExplanation.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .help(explanation)
        .popover(isPresented: $showingExplanation, arrowEdge: .bottom) {
            Text(explanation)
                .font(.callout)
                .frame(width: 220, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}

private struct ModelComparison {
    let left: UpscaleModel
    let right: UpscaleModel

    static let options: [Self] = [
        .init(left: .drct, right: .hat),
        .init(left: .drct, right: .seedvr2),
        .init(left: .hat, right: .seedvr2),
    ]

    var models: [UpscaleModel] { [left, right] }

    var title: String {
        "\(left.name) and \(right.name)"
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

    func start(input: URL, model: UpscaleModel, longEdge: Int, enlarges: Bool, tile: Int,
               startedAt: ContinuousClock.Instant,
               completion: @escaping @MainActor @Sendable (Result<URL?, Error>) -> Void) throws {
        guard !running else { return }
        let files = FileManager.default
        let directory = self.directory ?? files.temporaryDirectory.appending(path: "Mugi-\(UUID().uuidString)")
        let renderDirectory = directory.appending(path: UUID().uuidString)
        try files.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
        self.directory = directory
        let output = renderDirectory.appending(path: "result.png")
        let pipe = Pipe()
        let process: Process
        do {
            process = try EngineLocation().process(
                script: "upscale.py",
                arguments: [input.path, "-o", output.path, "--model", model.rawValue,
                            "--long-edge", String(longEdge), "--tile", String(tile), "--require-local-model"],
                pipe: pipe)
            try process.run()
        } catch {
            discardOutput(output)
            throw error
        }

        self.process = process
        self.startedAt = startedAt
        finishedElapsed = nil
        progress = nil
        status = enlarges ? "Preparing \(model.name)…" : "Resizing…"
        running = true

        observeEngine(process, pipe: pipe) { line in
            self.handle(line: line, model: model)
        } finished: { succeeded, diagnostic in
            let saved = succeeded && FileManager.default.fileExists(atPath: output.path)
            self.finish(output: output, succeeded: saved,
                        diagnostic: diagnostic ?? "The upscaling engine exited before saving an image.",
                        completion: completion)
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
        } else if line.hasPrefix("Status ") {
            status = String(line.dropFirst("Status ".count))
        } else if model == .seedvr2 && line.contains("━━━ Phase ") {
            if line.contains("Phase 1:") { status = "Preparing image for SeedVR2…" }
            if line.contains("Phase 2:") { status = "Reconstructing detail with SeedVR2…" }
            if line.contains("Phase 3:") { status = "Decoding the SeedVR2 result…" }
            if line.contains("Phase 4:") { status = "Finishing image…" }
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

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var name: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@main
struct UpscalerApp: App {
    @AppStorage("appearance") private var appearance = AppearanceChoice.system
    @StateObject private var job = UpscaleJob()
    @StateObject private var library = ModelLibrary()

    var body: some Scene {
        Window("Mugi", id: "upscaler") {
            UpscalerView()
                .environmentObject(job)
                .environmentObject(library)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(after: .toolbar) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        Label(choice.name, systemImage: choice.symbol).tag(choice)
                    }
                }
                .pickerStyle(.inline)
            }
        }
        Settings {
            SettingsView()
                .environmentObject(job)
                .environmentObject(library)
        }
    }
}

/// Output sizes offered in Settings, as the long edge in pixels.
enum OutputSize: Int, CaseIterable, Identifiable {
    case fourK = 3840, dci4K = 4096, eightK = 7680

    var id: Self { self }
    var name: String {
        switch self {
        case .fourK: "3,840 px (4K UHD)"
        case .dci4K: "4,096 px (DCI 4K)"
        case .eightK: "7,680 px (8K)"
        }
    }
}

private enum OutputSizeMode: String, CaseIterable, Identifiable {
    case scale = "Scale", longEdge = "Long edge", width = "Width", height = "Height"

    var id: Self { self }

    var initialValue: String {
        switch self {
        case .scale: "2"
        case .longEdge, .width, .height: String(OutputSize.fourK.rawValue)
        }
    }
}

private struct OutputSizeRequest: Equatable {
    static let maximumEdge = 8192

    var mode: OutputSizeMode
    var value: String

    init(mode: OutputSizeMode, value: String) {
        self.mode = mode
        self.value = value
    }

    init(stored: String, legacyLongEdge: Int) {
        let parts = stored.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let mode = parts.count == 2 ? OutputSizeMode(rawValue: String(parts[0])) : nil
        self.init(mode: mode ?? .longEdge, value: mode == nil ? String(legacyLongEdge) : String(parts[1]))
    }

    var stored: String { "\(mode.rawValue):\(value)" }

    var amount: Double? {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .scale {
            let separator = Locale.current.decimalSeparator ?? "."
            let decimal = input.replacingOccurrences(of: separator, with: ".")
                .replacingOccurrences(of: ",", with: ".")
            guard let factor = Double(decimal),
                  factor.isFinite, factor > 0 else { return nil }
            return factor
        }
        guard let pixels = Int(input), (1...Self.maximumEdge).contains(pixels) else { return nil }
        return Double(pixels)
    }

    func target(for photo: Photo) -> OutputTarget? {
        guard let amount else { return nil }
        let sourceEdge = max(photo.width, photo.height)
        let edge = switch mode {
        case .scale: amount * Double(sourceEdge)
        case .longEdge: amount
        case .width: amount * Double(sourceEdge) / Double(photo.width)
        case .height: amount * Double(sourceEdge) / Double(photo.height)
        }
        let rounded = max(1, edge.rounded(.toNearestOrEven))
        guard rounded <= Double(Self.maximumEdge) else { return nil }
        let longEdge = Int(rounded)
        func scaled(_ side: Int) -> Int {
            max(1, Int((Double(side) * Double(longEdge) / Double(sourceEdge)).rounded(.toNearestOrEven)))
        }
        return OutputTarget(width: scaled(photo.width), height: scaled(photo.height), sourceEdge: sourceEdge)
    }
}

private struct OutputTarget: Equatable {
    let width: Int
    let height: Int
    let sourceEdge: Int

    var longEdge: Int { max(width, height) }
    var enlarges: Bool { longEdge > sourceEdge }
    var scale: Double { Double(longEdge) / Double(sourceEdge) }
    var dimensions: String { "\(width.formatted()) × \(height.formatted())" }
    var scaleLabel: String {
        let decimalPlaces = scale < 0.01 ? 4 : 2
        return "\(scale.formatted(.number.precision(.fractionLength(0...decimalPlaces))))×"
    }

    func matches(_ photo: Photo?) -> Bool {
        photo?.width == width && photo?.height == height
    }
}

private struct OutputSizeFields: View {
    @Binding var request: OutputSizeRequest

    var body: some View {
        Picker("Size by", selection: Binding(get: { request.mode }, set: { mode in
            request = OutputSizeRequest(mode: mode, value: mode.initialValue)
        })) {
            ForEach(OutputSizeMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        LabeledContent(request.mode.rawValue) {
            TextField(request.mode.rawValue, text: $request.value)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 74)
            Text(request.mode == .scale ? "×" : "px")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if request.mode == .scale || request.mode == .longEdge {
                Menu("Presets") {
                    if request.mode == .scale {
                        ForEach([1.5, 2, 3, 4], id: \.self) { factor in
                            let value = factor.formatted(.number)
                            Button("\(value)×") { request.value = value }
                        }
                    } else {
                        ForEach(OutputSize.allCases) { size in
                            Button(size.name) { request.value = String(size.rawValue) }
                        }
                    }
                }
                .fixedSize()
                .accessibilityLabel("\(request.mode.rawValue) presets")
            }
        }
    }
}

enum OutputFormat: String, CaseIterable, Identifiable {
    case png, jpeg, tiff, heic

    var id: Self { self }
    var name: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .tiff: "TIFF"
        case .heic: "HEIC"
        }
    }
    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .tiff: "tiff"
        case .heic: "heic"
        }
    }
    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .heic: .heic
        }
    }
    var isLossy: Bool { self == .jpeg || self == .heic }
}

enum ImageExporter {
    /// Writes the engine's PNG result to `destination` in the chosen format.
    static func write(_ source: URL, to destination: URL, format: OutputFormat, quality: Double) throws {
        if format == .png {
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            return
        }
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(reader, 0, nil) else {
            throw UpscaleError.failed("Could not read the upscaled image.")
        }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        if format == .jpeg, hasAlpha {
            image = try flattenedOnWhite(image)
        }
        var properties: [CFString: Any] = [:]
        if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        if format == .tiff {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
        }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw UpscaleError.failed("This Mac cannot write \(format.name) files.")
        }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            throw UpscaleError.failed("Could not encode the image as \(format.name).")
        }
        try (data as Data).write(to: destination, options: .atomic)
    }

    /// A name in `directory` that does not overwrite an existing file.
    static func availableURL(in directory: URL, stem: String, fileExtension: String) -> URL {
        var candidate = directory.appending(path: "\(stem).\(fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(stem) \(number).\(fileExtension)")
            number += 1
        }
        return candidate
    }

    private static func flattenedOnWhite(_ image: CGImage) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw UpscaleError.failed("Could not prepare the image for JPEG.")
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else {
            throw UpscaleError.failed("Could not prepare the image for JPEG.")
        }
        return flattened
    }
}

private enum SettingsKey {
    static let all = ["appearance", "defaultModel", "longEdge", "defaultOutputSize", "tile", "autoSave",
                      "outputFolder", "outputFormat", "quality", "haptics", "settingsTab",
                      "showStats", "statsValues", "glass"]
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            ModelsSettings()
                .tabItem { Label("Models", systemImage: "shippingbox") }
                .tag("models")
            OutputSettings()
                .tabItem { Label("Output", systemImage: "square.and.arrow.down") }
                .tag("output")
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 500)
    }
}

private struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance = AppearanceChoice.system
    @AppStorage("defaultModel") private var defaultModel = UpscaleModel.defaultChoice
    @AppStorage("longEdge") private var longEdge = OutputSize.fourK.rawValue
    @AppStorage("defaultOutputSize") private var defaultOutputSize = ""
    @AppStorage("tile") private var tile = 256
    @AppStorage("haptics") private var haptics = true
    @AppStorage("showStats") private var showStats = true
    @AppStorage("statsValues") private var statsValues = StatsValues.percent
    @AppStorage("glass") private var glass = 1.0
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { choice in
                    Label(choice.name, systemImage: choice.symbol).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Glass") {
                HStack(spacing: 10) {
                    Slider(value: $glass, in: 0...1, step: 0.05)
                        .frame(width: 180)
                        .accessibilityLabel("Glass")
                        .accessibilityValue("\(Int(glass * 100)) percent")
                    Text("\(Int(glass * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .help("How see-through the window is. 100% is full frosted glass and 0% is a solid window color.")

            Section("Upscaling") {
                Picker("Default model", selection: $defaultModel) {
                    ForEach(UpscaleModel.allCases) { model in
                        Text(model.name).tag(model)
                    }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 8) {
                    Text(defaultModel.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ModelBars(model: defaultModel)
                }
            }

            Section("Default output size") {
                let request = OutputSizeRequest(stored: defaultOutputSize, legacyLongEdge: longEdge)
                OutputSizeFields(request: Binding(get: {
                    OutputSizeRequest(stored: defaultOutputSize, legacyLongEdge: longEdge)
                }, set: { defaultOutputSize = $0.stored }))
                Text(request.amount == nil
                     ? "Enter a positive scale or a pixel value from 1 to \(OutputSizeRequest.maximumEdge.formatted())."
                     : "Used when you open an image. Mugi preserves the original aspect ratio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Advanced") {
                Picker("Tile size", selection: $tile) {
                    ForEach([128, 192, 256, 320, 384], id: \.self) { size in
                        Text(size == 256 ? "\(size) px (default)" : "\(size) px").tag(size)
                    }
                }
                Text("For DRCT-L and HAT-L, smaller tiles use less memory but take longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System stats") {
                Toggle("Show CPU, memory, and GPU usage", isOn: $showStats)
                Picker("Values", selection: $statsValues) {
                    ForEach(StatsValues.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!showStats)
                Text("Used / total shows busy cores, memory in GB, and the GPU's share of memory. Hover a gauge for details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Toggle("Haptic feedback when an upscale finishes", isOn: $haptics)
            }

            Section {
                Button("Reset All Settings…", role: .destructive) { confirmingReset = true }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmingReset) {
            Button("Reset All Settings", role: .destructive) {
                SettingsKey.all.forEach { UserDefaults.standard.removeObject(forKey: $0) }
            }
        }
    }
}

private struct ModelsSettings: View {
    @EnvironmentObject private var library: ModelLibrary
    @EnvironmentObject private var job: UpscaleJob
    @State private var confirmRemoval = false

    var body: some View {
        Form {
            Section("Installed models") {
                bundledModel(.drct)
                bundledModel(.hat)
            }
            Section("Optional model") {
                LabeledContent {
                    if library.operation == .download {
                        SeedDownloadStatus()
                    } else if library.operation == .delete {
                        ProgressView().controlSize(.small)
                    } else if !library.seedInstalled {
                        Button(library.downloadTitle) { library.start(.download) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SeedVR2")
                        Text(seedStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if library.seedHasFiles {
                    HStack {
                        finderButton(.seedvr2)
                        Spacer()
                        Button("Delete Model…", role: .destructive) { confirmRemoval = true }
                            .disabled(library.operation != nil || job.running)
                    }
                }
                if let error = library.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: library.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            library.shutDown()
        }
        .confirmationDialog("Delete SeedVR2 model files?", isPresented: $confirmRemoval) {
            Button("Delete Model", role: .destructive) {
                if !job.running { library.start(.delete) }
            }
        } message: {
            Text("You can download SeedVR2 again from the model chooser.")
        }
    }

    private var seedStatus: String {
        if library.operation == .delete { return library.status }
        if library.operation == .download { return "Download in progress" }
        if library.seedInstalled { return "Downloaded · About 4 GB" }
        if library.seedHasFiles { return "Partial download · Resumable" }
        return "Download required · About 4 GB"
    }

    private func bundledModel(_ model: UpscaleModel) -> some View {
        let installed = library.localFiles[model]?.isEmpty == false
        return LabeledContent {
            finderButton(model).disabled(!installed)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                Text(installed ? "Included with Mugi" : "Model files missing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func finderButton(_ model: UpscaleModel) -> some View {
        Button("Show in Finder") { library.reveal(model) }
            .accessibilityLabel("Show \(model.name) in Finder")
    }
}

private struct OutputSettings: View {
    @AppStorage("autoSave") private var autoSave = false
    @AppStorage("outputFolder") private var outputFolder = ""
    @AppStorage("outputFormat") private var format = OutputFormat.png
    @AppStorage("quality") private var quality = 0.95

    var body: some View {
        Form {
            Section("Saving") {
                Toggle("Save automatically when an upscale finishes", isOn: $autoSave)
                LabeledContent("Output folder") {
                    HStack {
                        Text(outputFolder.isEmpty ? "Same folder as the original"
                                                  : (outputFolder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…", action: chooseFolder)
                        if !outputFolder.isEmpty {
                            Button("Reset") { outputFolder = "" }
                        }
                    }
                }
                Text("Automatic saves never overwrite a file. A number is added to the name if one already exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Format") {
                Picker("Image format", selection: $format) {
                    ForEach(OutputFormat.allCases) { format in
                        Text(format.name).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                if format.isLossy {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $quality, in: 0.5...1)
                                .frame(width: 180)
                            Text("\(Int((quality * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                Text(format.isLossy
                     ? "\(format.name) makes smaller files but discards some detail. Use PNG or TIFF to keep everything."
                     : "\(format.name) keeps every pixel exactly as upscaled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if !outputFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: outputFolder) }
        panel.begin { response in
            if response == .OK, let url = panel.url { outputFolder = url.path }
        }
    }
}

private extension Bundle {
    var mugiVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text("Mugi").font(.title.bold())
                Text("Version \(Bundle.main.mugiVersion)").font(.callout).foregroundStyle(.secondary)
            }
            Text("Upscale photos to 4K privately on your Mac. Everything runs on your GPU and nothing leaves your machine.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Text("Made by")
                    Link("Daffa Abhipraya", destination: URL(string: "https://abhipraya.dev")!)
                }
                Link("Source code on GitHub", destination: URL(string: "https://github.com/absolutepraya/mugi-upscale")!)
            }

            Divider().padding(.horizontal, 40)

            VStack(spacing: 4) {
                Text("Models by Philip Hofmann (Phips), CC BY 4.0")
                HStack(spacing: 10) {
                    Link("DRCT-L", destination: URL(string: "https://huggingface.co/Phips/4xNomos2_hq_drct-l")!)
                    Link("HAT-L", destination: URL(string: "https://huggingface.co/Phips/4xNomos8kSCHAT-L")!)
                }
                Link("SeedVR2 (ByteDance Seed)", destination: URL(string: "https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler")!)
                Text("The app and command line tool are under the PolyForm Noncommercial License 1.0.0.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
private final class UpscalerWindowState: ObservableObject {
    @Published var source: Photo?
    @Published var outputSize: OutputSizeRequest?
    @Published var results: [UpscaleModel: Photo] = [:]
    @Published var model = UpscaleModel(rawValue: UserDefaults.standard.string(forKey: "defaultModel") ?? "") ?? .defaultChoice
    @Published var comparison: ModelComparison?
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

/// Shows one image in its own resizable window that opens at most of the screen, one window per image.
@MainActor
private enum EnlargedPreviewWindow {
    private final class Window: NSWindow {
        override func cancelOperation(_ sender: Any?) { close() }
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        let closed: @MainActor () -> Void
        init(closed: @escaping @MainActor () -> Void) { self.closed = closed }
        func windowWillClose(_ notification: Notification) { closed() }
    }

    private static var open: [URL: (window: NSWindow, delegate: Delegate)] = [:]

    static func show(label: String, photo: Photo, near parent: NSWindow?) {
        if let existing = open[photo.url] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let area = (parent?.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: (area.width * 0.85).rounded(), height: (area.height * 0.85).rounded())
        let window = Window(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        window.title = "\(label), \(photo.dimensions)"
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 480, height: 360)
        window.contentView = NSHostingView(rootView: EnlargedPreviewView(label: label, photo: photo))
        window.setFrame(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height), display: false)
        let url = photo.url
        let delegate = Delegate { open[url] = nil }
        window.delegate = delegate
        open[url] = (window, delegate)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct EnlargedPreviewView: View {
    let label: String
    let photo: Photo

    var body: some View {
        Image(nsImage: photo.preview)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            .accessibilityLabel("\(label) image")
    }
}

struct UpscalerView: View {
    private static let formats: [UTType] = [.png, .jpeg, .webP, .tiff]
    private static let previewPadding: CGFloat = 20
    @EnvironmentObject private var job: UpscaleJob
    @EnvironmentObject private var library: ModelLibrary
    @StateObject private var window = UpscalerWindowState()
    @State private var showingOutputSize = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearance") private var appearance = AppearanceChoice.system
    @AppStorage("longEdge") private var longEdge = OutputSize.fourK.rawValue
    @AppStorage("defaultOutputSize") private var defaultOutputSize = ""
    @AppStorage("tile") private var tile = 256
    @AppStorage("autoSave") private var autoSave = false
    @AppStorage("outputFolder") private var outputFolder = ""
    @AppStorage("outputFormat") private var outputFormat = OutputFormat.png
    @AppStorage("quality") private var quality = 0.95
    @AppStorage("haptics") private var haptics = true
    @AppStorage("showStats") private var showStats = true
    @AppStorage("statsValues") private var statsValues = StatsValues.percent
    @AppStorage("glass") private var glass = 1.0
    @GestureState private var dragTranslation = CGSize.zero

    private var defaultSizeRequest: OutputSizeRequest {
        let request = OutputSizeRequest(stored: defaultOutputSize, legacyLongEdge: longEdge)
        if request.amount != nil { return request }
        return OutputSizeRequest(mode: .longEdge, value: String(longEdge))
    }

    private var outputTarget: OutputTarget? {
        guard let source = window.source else { return nil }
        return (window.outputSize ?? defaultSizeRequest).target(for: source)
    }

    var body: some View {
        VStack(spacing: 10) {
            comparisonWorkspace
                .padding(Self.previewPadding)
                .background(Color(nsColor: .windowBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 10, y: 3)

            controlBar
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .background {
            ZStack {
                FrostedBackground()
                Color(nsColor: .windowBackgroundColor).opacity(1 - glass)
            }
            .ignoresSafeArea()
        }
        .background(WindowChrome())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar(removing: defaultToolbarTitle)
        .frame(minWidth: 690, minHeight: 440)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            job.shutDown()
            library.shutDown()
        }
        .onAppear(perform: library.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.refresh()
        }
        .onOpenURL { select($0) }
        .onChange(of: outputTarget) { _, target in
            if let comparison = window.comparison,
               !comparison.models.allSatisfy({ target?.matches(window.results[$0]) == true }) {
                window.comparison = nil
            }
        }
        .onChange(of: appearance, initial: true) { _, choice in
            NSApp.appearance = choice.appearance
        }
        .toolbar {
            TitleItem()

            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            }
            #endif

            ToolbarItem(placement: .primaryAction) {
                Button(action: choose) {
                    Label("Add Photo", systemImage: "photo.badge.plus")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut("o")
                .help("Add a photo (⌘O)")
                .disabled(job.running)
            }

            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            #endif

            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceChoice.allCases) { choice in
                            Label(choice.name, systemImage: choice.symbol).tag(choice)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Appearance", systemImage: appearance.symbol)
                        .labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .help("Appearance: \(appearance.name)")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .help("Settings (⌘,)")
            }
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

    private var defaultToolbarTitle: ToolbarDefaultItemKind? {
        if #available(macOS 15, *) { .title } else { nil }
    }

    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.3) }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Model", selection: $window.model) {
                    ForEach(UpscaleModel.allCases) { model in
                        Text(model.name).tag(model)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(job.running)
                Text(window.model.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .animation(motion, value: window.model)
            }
            HStack(spacing: 12) {
                ModelBars(model: window.model)
                if window.model == .seedvr2 && outputTarget?.enlarges != false &&
                    !library.seedInstalled && library.operation == nil {
                    Spacer(minLength: 4)
                    Button(library.downloadTitle) { library.start(.download) }
                        .controlSize(.regular)
                        .actionButton(prominent: true)
                        .fixedSize()
                    Text("First use downloads about 4 GB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = library.error, window.model == .seedvr2 {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 16) {
                statusRow
                if showStats {
                    SystemMonitor(values: statsValues)
                        .fixedSize()
                }
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .animation(motion, value: job.running)
    }

    /// Progress for the running upscale, at the left end of the action row.
    private var loader: some View {
        ZStack {
            if job.running {
                Group {
                    if let progress = job.progress {
                        ProgressView(value: progress)
                            .accessibilityLabel("Tile progress")
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .animation(motion, value: job.progress)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(motion, value: job.running)
    }

    private var actionButtons: some View {
        let target = outputTarget
        let selectedDone = target?.matches(window.results[window.model]) == true
        let saveLabel = Label("Save \(outputFormat.name)…", systemImage: "square.and.arrow.down")
        return GlassGroup {
            HStack(spacing: 12) {
                if job.running {
                    Button(action: job.cancel) {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(job.cancelling)
                    .actionButton(prominent: false)
                    .transition(.blurReplace)
                } else {
                    outputSizeButton
                    Button { render([window.model]) } label: {
                        Label(target?.enlarges == false ? "Resize" : "Upscale",
                              systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(target?.enlarges == false ? "Resize to the selected output size (⌘↩)"
                          : "Upscale with \(window.model.name) (⌘↩)")
                    .disabled(target == nil || (target?.enlarges == true && window.model == .seedvr2 && !library.canUseSeed))
                    .actionButton(prominent: !selectedDone)
                    .transition(.blurReplace)
                }
                if let comparison = window.comparison {
                    Menu {
                        ForEach(comparison.models) { model in
                            Button("Save \(model.name)…") { save(model: model) }
                        }
                    } label: {
                        saveLabel
                    }
                    .fixedSize()
                    .disabled(job.running)
                    .actionButton(prominent: selectedDone)
                } else {
                    Button {
                        if let model = window.displayedModel { save(model: model) }
                    } label: {
                        saveLabel
                    }
                    .keyboardShortcut("s")
                    .disabled(window.displayedModel == nil || job.running)
                    .actionButton(prominent: selectedDone)
                }
            }
            .labelStyle(.titleAndIcon)
            .font(.body.weight(.semibold))
            .controlSize(.extraLarge)
            .buttonBorderShape(.capsule)
        }
        .animation(motion, value: job.running)
    }

    private var outputSizeButton: some View {
        Button { showingOutputSize.toggle() } label: {
            Label("Output Size", systemImage: "aspectratio")
        }
        .fixedSize()
        .disabled(window.source == nil)
        .actionButton(prominent: false)
        .popover(isPresented: $showingOutputSize, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                OutputSizeFields(request: Binding(get: { window.outputSize ?? defaultSizeRequest }, set: {
                    window.outputSize = $0
                    window.activity = nil
                }))
                if let target = outputTarget {
                    Text("\(target.dimensions) px at \(target.scaleLabel)")
                        .monospacedDigit()
                } else {
                    Text("Enter a size with a long edge from 1 to \(OutputSizeRequest.maximumEdge.formatted()) px.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Use Default") {
                        window.outputSize = nil
                        window.activity = nil
                    }
                    .disabled(window.outputSize == nil)
                    Spacer()
                    Button("Done") { showingOutputSize = false }
                        .keyboardShortcut(.defaultAction)
                        .disabled(outputTarget == nil)
                }
            }
            .padding(16)
            .frame(width: 340)
            .controlSize(.regular)
            .font(.body)
        }
    }

    private var statusSymbol: (name: String, color: Color)? {
        guard !job.running, let activity = window.activity else { return nil }
        if activity.hasPrefix("Ready") || activity.hasPrefix("Saved") {
            return ("checkmark.circle.fill", .green)
        }
        if activity.contains("cancelled") { return ("xmark.circle.fill", .secondary) }
        return nil
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if job.running {
                Text(job.status)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            } else {
                HStack(spacing: 8) {
                    if let target = outputTarget {
                        Text(target.dimensions)
                        Divider().frame(height: 10).accessibilityHidden(true)
                        Text(target.scaleLabel)
                    } else {
                        if window.source == nil {
                            Text("\(defaultSizeRequest.value)\(defaultSizeRequest.mode == .scale ? "×" : " px")")
                            Divider().frame(height: 10).accessibilityHidden(true)
                            Text("Original aspect ratio")
                        } else {
                            Text("Enter a valid output size")
                        }
                    }
                    Divider().frame(height: 10).accessibilityHidden(true)
                    Text(outputFormat.name)
                }
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityElement(children: .combine)
                if let activity = window.activity {
                    if let symbol = statusSymbol {
                        Image(systemName: symbol.name)
                            .foregroundStyle(symbol.color)
                            .symbolEffect(.bounce, value: window.activity)
                            .accessibilityHidden(true)
                    }
                    Text(activity)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                }
            }
            Spacer()
            if job.running {
                if let progress = job.progress {
                    Text("\(Int(progress * 100))%")
                        .contentTransition(.numericText(value: progress))
                        .accessibilityLabel("\(Int(progress * 100)) percent of tiles complete")
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    elapsedLabel(job.elapsed)
                }
            } else if let duration = job.finishedElapsed {
                elapsedLabel(duration)
            }
            if library.operation == .download {
                SeedDownloadStatus(showsModelName: true)
            } else if window.model == .seedvr2 && outputTarget?.enlarges != false {
                if library.operation == .delete {
                    Text(library.status)
                } else if library.seedInstalled {
                    Label("SeedVR2 downloaded", systemImage: "checkmark.circle")
                } else {
                    Text(library.seedHasFiles ? "Download incomplete" : "SeedVR2 download required")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(minHeight: 20)
        .animation(motion, value: window.activity)
        .animation(motion, value: job.progress)
    }

    private var comparisonWorkspace: some View {
        let leftModel = window.comparison?.left
        let rightModel = window.comparison?.right ?? window.displayedModel
        let result = rightModel.flatMap { window.results[$0] }
        let reference = result?.pixelSize ?? window.source?.pixelSize

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Zoom", selection: $window.zoom) {
                    Text("Fit").tag(PreviewZoom.fit)
                    Text("Contain").tag(PreviewZoom.contain)
                    Text("1:1").tag(PreviewZoom.actualPixels)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(window.source == nil)
                .help("Fit scales the whole image to the pane. Contain caps the scale at 1:1. At 1:1, drag either image to pan both.")
                Spacer()
                if window.comparison != nil {
                    Button("Show Original") { window.comparison = nil }
                        .disabled(job.running)
                        .actionButton(prominent: false)
                }
                Menu("Compare Models") {
                    ForEach(ModelComparison.options, id: \.title) { comparison in
                        Button(comparison.title) { compare(comparison) }
                    }
                }
                .controlSize(.regular)
                .disabled(outputTarget?.enlarges != true || job.running)
                .help("Choose two models to render and compare side by side.")
                .actionButton(prominent: false)
            }
            VStack(spacing: 0) {
                previewPanes(leftModel: leftModel, rightModel: rightModel, reference: reference)
                ZStack(alignment: .topLeading) {
                    Color.clear
                    if leftModel == nil, let source = window.source {
                        Text(source.url.lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.top, 3)
                    }
                }
                .frame(height: Self.previewPadding)
                HStack(spacing: 20) {
                    loader
                    actionButtons.fixedSize().layoutPriority(1)
                }
            }
        }
    }

    private func previewPanes(leftModel: UpscaleModel?, rightModel: UpscaleModel?, reference: CGSize?) -> some View {
        let spacing: CGFloat = 20
        let result = rightModel.flatMap { window.results[$0] }
        let resized = result.flatMap { result in
            window.source.map { max(result.width, result.height) <= max($0.width, $0.height) }
        } ?? false
        return GeometryReader { geometry in
            let paneWidth = max(0, (geometry.size.width - spacing) / 2)
            HStack(alignment: .top, spacing: spacing) {
                preview(label: leftModel?.name ?? "Original",
                        photo: leftModel.flatMap { window.results[$0] } ?? window.source,
                        reference: reference) {
                    VStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 88, height: 88)
                            .scaleEffect(window.dragging ? 1.12 : 1)
                            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.4), value: window.dragging)
                            .accessibilityHidden(true)
                        Text(window.dragging ? "Release to open" : "Drop an image here").font(.headline)
                        Button("Choose Image…", action: choose)
                            .actionButton(prominent: false)
                    }
                }
                .frame(width: paneWidth)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .opacity(window.dragging ? 1 : 0)
                        .animation(motion, value: window.dragging)
                        .allowsHitTesting(false)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, urls.count == 1, !job.running else { return false }
                    select(url)
                    return true
                } isTargeted: { targeted in
                    window.dragging = targeted && !job.running
                }

                preview(label: resized ? "Resized" : rightModel?.name ?? "Upscaled",
                        photo: result,
                        reference: reference) {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 30, weight: .light))
                        Text("Your result will appear here").font(.headline)
                    }
                }
                .frame(width: paneWidth)
            }
            .animation(motion, value: leftModel)
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
                    Text(photo.dimensions)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .contentTransition(.numericText())
                        .transition(.opacity)
                    Button {
                        EnlargedPreviewWindow.show(label: label, photo: photo, near: NSApp.keyWindow)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(label) at a larger size")
                    .accessibilityLabel("Open \(label) preview")
                }
            }
            .frame(minHeight: 20)
            .animation(motion, value: photo?.url)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary)
                if let photo, let reference {
                    GeometryReader { geometry in
                        previewImage(photo, label: label, reference: reference, size: geometry.size)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    placeholder()
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .animation(motion, value: photo?.url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.separator)
                    .allowsHitTesting(false)
            }
        }
    }

    private func previewImage(_ photo: Photo, label: String, reference: CGSize, size: CGSize) -> some View {
        let actualPixels = window.zoom == .actualPixels
        let viewport = ImageViewport(size: size, pixels: reference, displayScale: displayScale, zoom: window.zoom)
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
            window.outputSize = nil
            showingOutputSize = false
            window.results = [:]
            window.comparison = nil
            window.zoom = .fit
            window.pan = ImageViewport.center
            window.activity = nil
            job.clearResults()
        } catch {
            window.errorMessage = error.localizedDescription
        }
    }

    private func compare(_ comparison: ModelComparison) {
        guard let target = outputTarget, target.enlarges else { return }
        let missing = comparison.models.filter { !target.matches(window.results[$0]) }
        render(missing[...], comparison: comparison, target: target)
    }

    private func render(_ models: ArraySlice<UpscaleModel>, comparison: ModelComparison? = nil,
                        target: OutputTarget? = nil, startedAt: ContinuousClock.Instant = .now) {
        guard let source = window.source, let target = target ?? outputTarget, !job.running else { return }
        guard let model = models.first else {
            window.comparison = comparison
            return
        }
        if target.enlarges && models.contains(.seedvr2) {
            library.refresh()
            guard library.canUseSeed else {
                window.model = .seedvr2
                window.activity = "Download SeedVR2 before upscaling with it."
                return
            }
        }
        window.activity = nil
        do {
            try job.start(input: source.url, model: model, longEdge: target.longEdge, enlarges: target.enlarges,
                          tile: tile, startedAt: startedAt) { outcome in
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
                    let saved = autoSaveResult(model: model)
                    if models.count > 1 {
                        render(models.dropFirst(), comparison: comparison, target: target, startedAt: startedAt)
                    } else {
                        if let comparison { window.comparison = comparison }
                        if !saved { window.activity = "Ready to save" }
                        if haptics {
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                        }
                    }
                } catch {
                    window.errorMessage = error.localizedDescription
                }
            }
        } catch {
            window.errorMessage = error.localizedDescription
        }
    }

    private func outputDirectory(for source: Photo) -> URL {
        outputFolder.isEmpty ? source.url.deletingLastPathComponent() : URL(fileURLWithPath: outputFolder, isDirectory: true)
    }

    private func outputStem(for model: UpscaleModel, source: Photo, result: Photo) -> String {
        let longEdge = max(result.width, result.height)
        let tag = switch longEdge {
        case 3840, 4096: "4k"
        case 7680: "8k"
        default: "\(longEdge)px"
        }
        let operation = longEdge <= max(source.width, source.height) ? "resize" : model.rawValue
        return "\(source.url.deletingPathExtension().lastPathComponent)-\(operation)-\(tag)"
    }

    /// Saves a finished result to the default folder when auto-save is on. Returns whether it saved.
    private func autoSaveResult(model: UpscaleModel) -> Bool {
        guard autoSave, let result = window.results[model], let source = window.source else { return false }
        do {
            let directory = outputDirectory(for: source)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = ImageExporter.availableURL(
                in: directory, stem: outputStem(for: model, source: source, result: result), fileExtension: outputFormat.fileExtension)
            try ImageExporter.write(result.url, to: destination, format: outputFormat, quality: quality)
            window.activity = "Saved \(destination.lastPathComponent)"
            return true
        } catch {
            window.errorMessage = "Auto-save failed. \(error.localizedDescription)"
            return false
        }
    }

    private func save(model: UpscaleModel) {
        guard let result = window.results[model], let source = window.source else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [outputFormat.type]
        panel.nameFieldStringValue = "\(outputStem(for: model, source: source, result: result)).\(outputFormat.fileExtension)"
        panel.directoryURL = outputDirectory(for: source)
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                guard destination.resolvingSymlinksInPath() != source.url.resolvingSymlinksInPath() else {
                    throw UpscaleError.failed("Choose a different filename to keep the original image.")
                }
                try ImageExporter.write(result.url, to: destination, format: outputFormat, quality: quality)
                window.activity = "Saved \(destination.lastPathComponent)"
            } catch {
                window.errorMessage = error.localizedDescription
            }
        }
    }
}


private extension View {
    func actionButton(prominent: Bool) -> some View {
        modifier(ActionButtonStyle(prominent: prominent))
    }
}

/// Liquid Glass buttons on macOS 26 and later, with the standard bordered styles before that
/// or when built with a toolchain that predates the macOS 26 SDK.
private struct ActionButtonStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
        #else
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
        #endif
    }
}

/// Lets neighbouring glass buttons blend and refract together on macOS 26 and later.
private struct GlassGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}


/// The glass window frame: Liquid Glass on macOS 26 and later, a behind-window blur before that.
private struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let view = NSGlassEffectView()
            view.style = .regular
            view.cornerRadius = 0
            return view
        }
        #endif
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Makes the window itself see-through so the frosted frame shows, and blends in the title bar.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
    }
}


/// The compact title at the leading edge of the toolbar.
private struct TitleItem: ToolbarContent {
    private var title: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text("Mugi").font(.headline)
            Text("v\(Bundle.main.mugiVersion)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Version \(Bundle.main.mugiVersion)")
        }
        .fixedSize()
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { title }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { title }
        }
        #else
        ToolbarItem(placement: .navigation) { title }
        #endif
    }
}
