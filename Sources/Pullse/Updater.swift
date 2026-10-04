import AppKit
import CryptoKit
import Observation
import PullseCore

/// Finds newer GitHub releases of Pullse and installs them in place.
///
/// Releases are ad-hoc signed, not notarized. That's fine here: files the app downloads
/// itself aren't quarantined, so Gatekeeper never sees the update. What protects the swap
/// instead is the check chain in `install()`: HTTPS from GitHub with the user's token, the
/// published SHA-256, then the bundle id, version and code signature of what was unpacked.
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle, checking, downloading, installing
    }

    private(set) var available: AvailableUpdate?
    private(set) var lastChecked: Date?
    private(set) var error: String?
    private(set) var phase: Phase = .idle

    /// Versions of the running app, stamped into the bundle by scripts/build-app.sh.
    private(set) var version: String
    private(set) var build: String
    /// owner/name of the repo this build came from; nil disables updates.
    let repository: String?
    /// Set when the app was built on this Mac rather than by GitHub Actions: the commit it
    /// was built from, with "-modified" when it had uncommitted changes.
    private(set) var localBuild: String?

    static let checkInterval: Duration = .seconds(60 * 60)

    @ObservationIgnored private let settings: SettingsModel
    @ObservationIgnored private let client: GitHubClient
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var previewInstallable: Bool?
    /// How long an automatic install waits between looks at whether Pullse is in use.
    static let busyRetry: Duration = .seconds(30)

    init(settings: SettingsModel, client: GitHubClient, bundle: Bundle = .main) {
        self.settings = settings
        self.client = client
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let repo = bundle.object(forInfoDictionaryKey: "PullseUpdateRepository") as? String
        repository = repo.flatMap { UpdateChecker.isValidRepository($0) ? $0 : nil }
        localBuild = bundle.object(forInfoDictionaryKey: "PullseLocalBuild") as? String
    }

    /// "local build 5898aea, modified", or nil for a release or CI build.
    var localBuildDescription: String? {
        guard let localBuild else { return nil }
        let commit = localBuild.replacingOccurrences(of: "-modified", with: "")
        return "local build \(commit)" + (localBuild.hasSuffix("-modified") ? ", modified" : "")
    }

    var currentVersion: SemanticVersion? { SemanticVersion(version) }

    var isBusy: Bool { phase != .idle }

    /// In-place installs only happen for an app that lives in an Applications folder we
    /// can write to. A copy run from `build/` or a read-only volume gets "Download".
    var canInstallInPlace: Bool {
        if let previewInstallable { return previewInstallable }
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let parent = bundle.deletingLastPathComponent().path
        let applications = ["/Applications", NSHomeDirectory() + "/Applications"]
        return bundle.pathExtension == "app" && applications.contains(parent)
            && FileManager.default.isWritableFile(atPath: parent)
            && FileManager.default.isWritableFile(atPath: bundle.path)
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scheduledCheck()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    private func scheduledCheck() async {
        guard settings.current.checkForUpdates || settings.current.autoUpdate else { return }
        await check()
        guard settings.current.autoUpdate, available != nil, canInstallInPlace else { return }
        // Installing quits and relaunches Pullse; never do that under someone reading the
        // menu or changing a setting. Wait until both are closed.
        while Self.isInUse {
            try? await Task.sleep(for: Self.busyRetry)
            if Task.isCancelled || !settings.current.autoUpdate { return }
        }
        await install()
    }

    /// The menu or the Settings window is open. Only the menu bar item's own window is
    /// always visible, so any other visible window means someone is looking at Pullse.
    static var isInUse: Bool {
        NSApp.windows.contains { $0.isVisible && !$0.className.contains("StatusBarWindow") }
    }

    /// Look for a newer release. Also backs the "Check now" button.
    func check() async {
        guard !isBusy else { return }
        guard let repository, let current = currentVersion else {
            error = "This build has no update source."
            return
        }
        phase = .checking
        defer { phase = .idle }
        do {
            let releases = try await client.releases(repository: repository)
            available = UpdateChecker.latest(
                from: releases, current: current,
                includePrereleases: settings.current.includePrereleases
            )
            lastChecked = Date()
            error = nil
        } catch {
            self.error = "Update check failed: \(error.localizedDescription)"
        }
    }

    func openReleasePage() {
        if let link = available?.pageURL, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Download, verify, swap and relaunch. Returns only on failure; on success the app
    /// quits and the new version starts.
    func install() async {
        guard !isBusy, let update = available else { return }
        guard canInstallInPlace else {
            openReleasePage()
            return
        }
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pullse-update-\(UUID().uuidString)", isDirectory: true)
        do {
            phase = .downloading
            let archive = try await client.download(update.archive)
            let checksumText = String(decoding: try await client.download(update.checksum), as: UTF8.self)

            phase = .installing
            guard let expected = UpdateChecker.checksum(in: checksumText, for: update.archive.name) else {
                throw UpdateError.verification("the release has no usable checksum")
            }
            let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                throw UpdateError.verification("the download doesn't match its published checksum")
            }

            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zip = workDir.appendingPathComponent(update.archive.name)
            try archive.write(to: zip)
            let unpacked = workDir.appendingPathComponent("unpacked", isDirectory: true)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let newApp = unpacked.appendingPathComponent("Pullse.app")
            try await verify(newApp, expecting: update.version)

            try launchSwap(replacing: Bundle.main.bundleURL, with: newApp)
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            self.error = "Update failed: \(error.localizedDescription)"
            phase = .idle
        }
    }

    /// The unpacked app must be the same app, the promised version, and intact.
    private func verify(_ app: URL, expecting version: SemanticVersion) async throws {
        guard let info = Bundle(url: app)?.infoDictionary else {
            throw UpdateError.verification("the download doesn't contain Pullse.app")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.verification(
                "the update has bundle id \(info["CFBundleIdentifier"] as? String ?? "none"), "
                    + "this app is \(Bundle.main.bundleIdentifier ?? "none")"
            )
        }
        guard (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init) == version else {
            throw UpdateError.verification("the update's version doesn't match the release")
        }
        try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    /// Hands the swap to a detached shell that waits for this process to exit, moves the
    /// new bundle into place (restoring the old one if that fails) and opens the result.
    private func launchSwap(replacing target: URL, with newApp: URL) throws {
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent(".Pullse-previous-\(UUID().uuidString).app")
        let script = """
        pid="$1"; target="$2"; new="$3"; backup="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        mv "$target" "$backup" || { open "$target"; exit 1; }
        if mv "$new" "$target"; then
            rm -rf "$backup"
        else
            mv "$backup" "$target"
        fi
        open "$target"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", script, "pullse-update",
            String(ProcessInfo.processInfo.processIdentifier), target.path, newApp.path, backup.path,
        ]
        try process.run()
    }

    /// Runs a tool off the main actor, so the menu stays responsive while it works.
    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached { try runBlocking(tool, arguments) }.value
    }

    nonisolated private static func runBlocking(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.verification("\((tool as NSString).lastPathComponent) failed: \(detail)")
        }
    }

    /// Demo GIFs only: pretend to be `version` in Applications, with a check that
    /// found `update`.
    func showAvailable(_ update: AvailableUpdate, runningVersion version: String, build: String) {
        self.version = version
        self.build = build
        localBuild = nil
        previewInstallable = true
        available = update
        lastChecked = Date()
    }

    /// Demo GIFs only: look like a release, even though the demo runs from a local build.
    func showAsRelease() {
        localBuild = nil
    }

    /// Demo GIFs only: show an install at `phase` without doing one.
    func showPhase(_ phase: Phase) {
        self.phase = phase
    }
}

enum UpdateError: LocalizedError {
    case verification(String)

    var errorDescription: String? {
        switch self {
        case .verification(let reason): return reason
        }
    }
}
