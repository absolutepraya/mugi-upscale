import AppKit
import CryptoKit
import SwiftUI

// MARK: Releases

/// A published Mugi release that the app can update to.
struct AppRelease: Equatable, Sendable {
    let version: String
    let pageURL: URL
    let dmgURL: URL
    let checksumURL: URL
}

enum AppVersion {
    /// Compares dotted numeric versions such as 0.10.0 and 0.9.2.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = components(candidate), old = components(current)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
    }

    let tagName: String
    let htmlUrl: URL
    let assets: [Asset]

    var release: AppRelease? {
        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        guard let dmg = assets.first(where: { $0.name.hasSuffix("-arm64.dmg") }),
              let checksum = assets.first(where: { $0.name == dmg.name + ".sha256" }) else { return nil }
        return AppRelease(version: version, pageURL: htmlUrl,
                          dmgURL: dmg.browserDownloadUrl, checksumURL: checksum.browserDownloadUrl)
    }
}

enum UpdateError: LocalizedError {
    case badResponse
    case noRelease
    case checksumMismatch
    case invalidApp(String)
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: "GitHub did not return a usable answer. Try again later."
        case .noRelease: "The latest release has no installable download."
        case .checksumMismatch: "The download did not match its checksum, so it was discarded."
        case .invalidApp(let reason): "The downloaded app did not pass its checks: \(reason)"
        case .tool(let output): "Installing failed: \(output)"
        }
    }
}

// MARK: Updater

/// Finds newer releases on GitHub and replaces the installed app with one.
/// Nothing is installed or restarted until the user asks, and a failure leaves the installed app untouched.
@MainActor
final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(Double?)
        case verifying
        case installing
        case failed(String, AppRelease?)
    }

    private static let latestRelease = URL(string: "https://api.github.com/repos/absolutepraya/mugi-upscale/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let checkKey = "updateCheck"
    private static let lastCheckKey = "lastUpdateCheck"

    @Published private(set) var state = State.idle
    @Published private(set) var lastChecked: Date?
    private var pending: AppRelease?

    /// Local builds are not releases, so they never look for updates.
    let isDevelopmentBuild = Bundle.main.mugiVersion == "dev"

    var release: AppRelease? {
        switch state {
        case .available(let release), .failed(_, let release?): release
        case .downloading, .verifying, .installing: pending
        default: nil
        }
    }

    var busy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing: true
        default: false
        }
    }

    /// False when the app sits where it cannot replace itself, such as a disk image or a read-only folder.
    var canInstallInPlace: Bool {
        let url = Bundle.main.bundleURL
        return !url.path.hasPrefix("/Volumes/")
            && FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        lastChecked = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    /// Checks once a day at launch unless the user turned that off.
    func checkOnLaunch() async {
        let enabled = UserDefaults.standard.object(forKey: Self.checkKey) as? Bool ?? true
        guard !isDevelopmentBuild, enabled else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        guard !isDevelopmentBuild, !busy else { return }
        if userInitiated { state = .checking }
        do {
            var request = URLRequest(url: Self.latestRelease, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Mugi", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let latest = try decoder.decode(GitHubRelease.self, from: data)
            let now = Date()
            lastChecked = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
            if let release = latest.release, AppVersion.isNewer(release.version, than: Bundle.main.mugiVersion) {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            if userInitiated {
                state = .failed("Could not check for updates. \(error.localizedDescription)", nil)
            } else if case .checking = state {
                state = .idle
            }
        }
    }

    /// Downloads, verifies, and installs the available release, then relaunches.
    func install() async {
        guard case .available(let release) = state, canInstallInPlace else { return }
        pending = release
        let work = FileManager.default.temporaryDirectory.appending(path: "mugi-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            state = .downloading(nil)
            let dmg = work.appending(path: "Mugi.dmg")
            try await download(release.dmgURL, to: dmg)
            state = .verifying
            let checksum = try await expectedChecksum(from: release.checksumURL)
            state = .installing
            let installed = Bundle.main.bundleURL
            let version = release.version
            try await Task.detached {
                try UpdateInstaller.install(dmg: dmg, checksum: checksum, version: version, over: installed, work: work)
            }.value
            try? FileManager.default.removeItem(at: work)
            try relaunch(installed)
        } catch {
            try? FileManager.default.removeItem(at: work)
            state = .failed(error.localizedDescription, release)
        }
    }

    /// Returns a failed update to the available state so the user can try again.
    func retry() {
        if case .failed(_, let release?) = state { state = .available(release) }
    }

    private func expectedChecksum(from url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Mugi", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let token = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first else {
            throw UpdateError.badResponse
        }
        return String(token).lowercased()
    }

    private func download(_ url: URL, to destination: URL) async throws {
        let delegate = DownloadDelegate(destination: destination) { [weak self] fraction in
            Task { @MainActor in
                if case .downloading = self?.state { self?.state = .downloading(fraction) }
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: URLRequest(url: url)).resume()
        }
    }

    /// Starts the new copy once this process has exited, then quits.
    private func relaunch(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -n \"$2\"",
                             "sh", String(getpid()), app.path]
        try process.run()
        NSApp.terminate(nil)
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<Void, Error>?
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void
    private var moveError: Error?
    private var lastPercent = -1

    init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let percent = Int(fraction * 100)
        guard percent != lastPercent else { return }
        lastPercent = percent
        progress(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do { try FileManager.default.moveItem(at: location, to: destination) } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        if let error {
            continuation?.resume(throwing: error)
        } else if status != 200 {
            continuation?.resume(throwing: UpdateError.badResponse)
        } else if let moveError {
            continuation?.resume(throwing: moveError)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

/// Checks a downloaded disk image and swaps its app in for the installed one.
enum UpdateInstaller {
    static let productionIdentifier = "dev.abhipraya.local-upscaler"

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func install(dmg: URL, checksum: String, version: String, over installed: URL, work: URL) throws {
        guard try sha256(of: dmg) == checksum else { throw UpdateError.checksumMismatch }

        let mount = work.appending(path: "mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                     "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

        let apps = try FileManager.default.contentsOfDirectory(
            at: mount, includingPropertiesForKeys: [.isSymbolicLinkKey]
        ).filter { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
        guard let app = apps.first, let bundle = Bundle(url: app) else {
            throw UpdateError.invalidApp("the disk image has no app.")
        }
        guard bundle.bundleIdentifier == productionIdentifier else {
            throw UpdateError.invalidApp("it is not Mugi.")
        }
        guard bundle.mugiVersion == version else {
            throw UpdateError.invalidApp("its version does not match the release.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        // Stage next to the installed app so the swap is a single rename, and never touch the original before it succeeds.
        let staged = installed.deletingLastPathComponent().appending(path: ".Mugi-update-\(UUID().uuidString).app")
        do {
            try run("/usr/bin/ditto", [app.path, staged.path])
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.tool(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}

// MARK: Views

/// What the updater is doing and what the user can do about it. Shared by the popover and About.
struct UpdatePanel: View {
    @EnvironmentObject private var updater: AppUpdater
    @EnvironmentObject private var job: UpscaleJob
    var centered = false

    private var alignment: HorizontalAlignment { centered ? .center : .leading }

    var body: some View {
        VStack(alignment: alignment, spacing: 10) {
            switch updater.state {
            case .idle:
                EmptyView()
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…")
                }
            case .upToDate:
                Label("Mugi is up to date.", systemImage: "checkmark.circle")
            case .available(let release):
                available(release)
            case .downloading(let fraction):
                VStack(alignment: alignment, spacing: 6) {
                    Text("Downloading Mugi \(updater.release?.version ?? "")…")
                    if let fraction {
                        ProgressView(value: fraction)
                            .accessibilityLabel("Download progress")
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            case .verifying:
                Text("Verifying the download…")
            case .installing:
                Text("Installing. Mugi restarts when this finishes.")
            case .failed(let message, let release):
                VStack(alignment: alignment, spacing: 8) {
                    Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let release {
                        HStack {
                            if updater.canInstallInPlace { Button("Try Again") { updater.retry() } }
                            Button("Open Release Page") { NSWorkspace.shared.open(release.pageURL) }
                        }
                    }
                }
            }
        }
        .font(.callout)
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private func available(_ release: AppRelease) -> some View {
        VStack(alignment: alignment, spacing: 8) {
            Text("Mugi \(release.version) is available").font(.headline)
            Link("Release notes", destination: release.pageURL)
            if updater.canInstallInPlace {
                Button("Update and Restart") { Task { await updater.install() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(job.running)
                if job.running {
                    Text("Finish or cancel the current upscale first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Download") { NSWorkspace.shared.open(release.pageURL) }
                    .buttonStyle(.borderedProminent)
                Text("Mugi cannot replace itself where it is now, so install the new version from the release page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The Update button beside the version in the title bar. It only appears when there is something to install.
struct UpdateBadge: View {
    @EnvironmentObject private var updater: AppUpdater
    @State private var showing = false

    var body: some View {
        if let release = updater.release {
            Button { showing.toggle() } label: {
                Text("Update")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Mugi \(release.version) is available")
            .accessibilityLabel("Update to Mugi \(release.version)")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                UpdatePanel()
                    .padding(14)
                    .frame(width: 280)
            }
        }
    }
}

/// The updates block on the About page.
struct UpdateSection: View {
    @EnvironmentObject private var updater: AppUpdater
    @AppStorage("updateCheck") private var checkAutomatically = true

    var body: some View {
        VStack(spacing: 10) {
            if updater.isDevelopmentBuild {
                Text("This is a development build, so updates are off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                UpdatePanel(centered: true)
                    .frame(maxWidth: 300)
                HStack(spacing: 14) {
                    Button("Check for Updates") { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.busy)
                    Toggle("Check automatically", isOn: $checkAutomatically)
                        .toggleStyle(.checkbox)
                }
                if let lastChecked = updater.lastChecked {
                    Text("Last checked \(lastChecked.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
