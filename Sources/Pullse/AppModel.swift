import AppKit
import Observation
import PullseCore

@MainActor
@Observable
final class AppModel {
    private(set) var history: [PREvent] = []
    /// My open PRs as of the latest successful poll, and the org it polled. Not saved, so
    /// empty until the first poll after launch.
    private var polledOpenPRs: (org: String, prs: [OpenPullRequest])?
    private(set) var lastPoll: Date?
    private(set) var lastError: String?
    private(set) var isPolling = false
    /// Set when macOS won't show Pullse's notifications (turned off, never allowed, or no
    /// banners), in words for the user.
    private(set) var notificationProblem: String?

    var unreadCount: Int { history.filter(\.isUnread).count }

    /// The open PRs to show: none from another org (the org was just changed and not polled
    /// yet), and none from muted repositories.
    var openPRs: [OpenPullRequest] {
        guard let polled = polledOpenPRs, polled.org == settings.current.organization else { return [] }
        return ActivityGroups.visible(polled.prs, settings: settings.current.detectorSettings)
    }

    var openPullRequests: Int { openPRs.count }

    let settings: SettingsModel
    let updater: Updater
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private let client: GitHubClient
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private var state: PersistedState
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// A poll was asked for while one was running; run another as soon as it ends.
    @ObservationIgnored private var pollAgain = false
    @ObservationIgnored private var activationObservers: [NSObjectProtocol] = []

    convenience init() {
        self.init(store: StateStore(), settings: SettingsModel())
    }

    init(store: StateStore, settings: SettingsModel) {
        self.store = store
        self.settings = settings
        let client = GitHubClient()
        self.client = client
        updater = Updater(settings: settings, client: client)
        state = store.load()
        history = state.history
    }

    /// Demo GIFs only: show a finished poll without talking to GitHub.
    func showAsPolled(openPRs: [OpenPullRequest], at date: Date) {
        polledOpenPRs = (settings.current.organization ?? "", openPRs)
        lastPoll = date
        lastError = nil
    }

    func start() {
        notifier.activate()
        Task { await refreshNotificationStatus() }
        watchForNotificationSettingChanges()
        announceUpdateIfNew()
        restartLoop()
        updater.start()
    }

    /// Once per new version: "Pullse updated to x.y.z", after an update or a reinstall.
    private func announceUpdateIfNew() {
        let current = updater.version
        defer {
            if state.lastRunVersion != current {
                state.lastRunVersion = current
                save()
            }
        }
        guard let previous = state.lastRunVersion.flatMap(SemanticVersion.init),
              let now = SemanticVersion(current), now > previous,
              settings.current.notifyAfterUpdate
        else { return }
        let notes = updater.repository.map { "https://github.com/\($0)/releases/tag/v\(current)" }
        notifier.sendUpdated(to: current, notesURL: notes ?? "https://github.com")
    }

    /// Poll now and restart the timer (also picks up a changed interval).
    func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(self?.settings.current.pollInterval ?? 60))
            }
        }
    }

    /// Poll now. If a poll is already running, another one follows it rather than the
    /// request being dropped, so a caller always gets data fetched after it asked.
    func poll() async {
        guard !isPolling else {
            pollAgain = true
            return
        }
        isPolling = true
        defer { isPolling = false }
        repeat {
            pollAgain = false
            // Unstructured, so restarting the loop (which cancels the task awaiting this)
            // doesn't cancel the request half way and surface a spurious error.
            await Task { await self.fetchAndNotify() }.value
        } while pollAgain
    }

    private func fetchAndNotify() async {
        await refreshNotificationStatus()
        settings.reloadIfChanged()
        if let problem = settings.error {
            lastError = problem
            return
        }
        guard let org = settings.current.organization else {
            lastError = "Choose the GitHub organization to watch in Settings…"
            return
        }
        let settings = settings.current.detectorSettings
        // On the very first poll everything is baselined anyway, so skip the mentions
        // query; afterwards look back a little past the previous poll.
        let mentionsSince = settings.mentions
            ? state.seen.lastPollAt.map { $0.addingTimeInterval(-10 * 60) }
            : nil

        do {
            let snapshot = try await client.snapshot(org: org, mentionsSince: mentionsSince)
            let (events, seen) = EventDetector.detect(
                snapshot, state: state.seen, settings: settings, now: Date()
            )
            state.seen = seen
            state.record(events)
            history = state.history
            polledOpenPRs = (org, snapshot.myPullRequests.map(OpenPullRequest.init))
            lastPoll = Date()
            lastError = nil
            save()
            if !events.isEmpty {
                notifier.post(events)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// `--check`: one live fetch, print what the last 24 hours would have notified
    /// about (without notifying or touching saved state), then quit.
    func check() async {
        if let problem = settings.error {
            print("error: \(problem)")
            exit(1)
        }
        guard let org = settings.current.organization else {
            print("error: no organization set. Add \"org\" to \(settings.file.url.path) or set it in Settings….")
            exit(1)
        }
        do {
            let settings = settings.current.detectorSettings
            let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
            let snapshot = try await client.snapshot(
                org: org, mentionsSince: settings.mentions ? dayAgo : nil
            )
            let (events, _) = EventDetector.detect(
                snapshot, state: SeenState(lastPollAt: dayAgo), settings: settings, now: Date()
            )
            print("Logged in as \(snapshot.login) · \(snapshot.myPullRequests.count) open PRs in \(org) · \(snapshot.mentionedPullRequests.count) PRs mentioning you")
            print("Notifications: \(await notifier.problem() ?? "allowed, with banners")")
            await updater.check()
            if let error = updater.error {
                print("Updates: \(error)")
            } else if let update = updater.available {
                print("Updates: \(update.version.description) is available (\(update.pageURL))")
            } else {
                print("Updates: \(updater.version) is up to date (\(updater.repository ?? "no update source"))")
            }
            if let local = updater.localBuildDescription {
                print("Build: \(local)")
            }
            print("Open PRs:")
            for pr in ActivityGroups.visible(snapshot.myPullRequests.map(OpenPullRequest.init), settings: settings) {
                let status = [
                    pr.ci.map { "CI \($0)" }, pr.isDraft ? "draft" : pr.review.map { "review \($0)" },
                ].compactMap { $0 }
                print("  \(pr.prLabel)  \(pr.title.prefix(50))  \(status.isEmpty ? "-" : status.joined(separator: ", "))")
            }
            print("\(events.count) events in the last 24h:")
            for event in events {
                print("  \(event.date.formatted(date: .omitted, time: .shortened))  \(event.prLabel)  \(event.headline)  \(event.snippet.prefix(60))")
            }
            exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        for index in state.history.indices {
            state.history[index].isUnread = false
        }
        history = state.history
        save()
    }

    /// The permission can change in System Settings at any time. Re-read it whenever Pullse
    /// is brought forward (opening the menu or Settings does that), rather than relying on
    /// the menu's onAppear, which a menu bar popover doesn't reliably fire on every open.
    private func watchForNotificationSettingChanges() {
        let names = [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification]
        activationObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshNotificationStatus() }
            }
        }
    }

    func refreshNotificationStatus() async {
        notificationProblem = await notifier.problem()
    }

    /// "Send test notification": posts one and adds the same item to the activity list,
    /// linking to the repository Pullse was built from.
    func sendTest() async {
        await notifier.requestPermissionIfNeeded()
        await refreshNotificationStatus()
        let link = updater.repository.map { "https://github.com/\($0)" } ?? "https://github.com"
        let event = PREvent(
            id: "test-\(UUID().uuidString)", kind: .test, repo: "Pullse", number: 0,
            prTitle: "Test notification", prURL: "pullse:test", author: nil,
            headline: "Test notification",
            snippet: notificationProblem.map { "Added here, but not shown by macOS: \($0)" }
                ?? "Notifications work. Click to open the Pullse repository.",
            url: link, date: Date()
        )
        state.record([event])
        history = state.history
        save()
        notifier.sendTest(event)
    }

    func clearHistory() {
        state.history = []
        history = []
        save()
    }

    func open(_ event: PREvent) {
        if let index = state.history.firstIndex(where: { $0.id == event.id }) {
            state.history[index].isUnread = false
            history = state.history
            save()
        }
        // History may predate the link check, so check again right before opening.
        if let link = GitHubLink.safe(event.url, fallback: event.prURL), let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    /// A group heading in the menu.
    func open(_ group: ActivityGroups.Group) {
        if let link = group.link, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    private func save() {
        do {
            try store.save(state)
        } catch {
            lastError = "Couldn't save state: \(error.localizedDescription)"
        }
    }
}
