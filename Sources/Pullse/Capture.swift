import AppKit
import PullseCore
import SwiftUI

/// Drawing Pullse's real views off-screen, with made-up data, for the README's GIFs
/// (`Demo.swift`). The app never talks to GitHub or touches the real settings and state
/// files here, and since it draws from an off-screen window of this process, no Screen
/// Recording permission is needed.
@MainActor
enum Capture {
    /// Drawn as a rounded panel, the way the menu bar shows the menu.
    static func popover<V: View>(_ view: V) -> some View {
        view
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .padding(1)
    }

    /// Draws `view` in an off-screen key window at its fitting size.
    static func image<V: View>(
        of view: V, appearance: NSAppearance.Name, settle: Duration = .milliseconds(400)
    ) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        let window = KeyWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        // Swift owns the window; AppKit's default of also releasing it on close would
        // free it twice.
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        // Controls in a window that isn't key are drawn inactive (switches turn gray),
        // so make the off-screen window key for the picture.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        // Let SwiftUI lay out, size the window to fit, then let it draw at that size.
        try await Task.sleep(for: settle)
        window.setContentSize(host.fittingSize)
        window.makeFirstResponder(nil)  // no focused text field with its text selected
        try await Task.sleep(for: settle)

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// An app model backed by throwaway files holding sample settings and history, with
    /// an update to 1.4.0 waiting unless `update` is false.
    static func sampleModel(
        events: [PREvent] = sampleEvents(now: Date()), update: Bool = true
    ) throws -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pullse-capture-\(UUID().uuidString)", isDirectory: true)

        var settings = PullseSettings()
        settings.org = "acme"
        settings.mutedRepos = ["sandbox"]
        settings.showOpenPullRequests = true
        let settingsFile = SettingsFile(url: dir.appendingPathComponent("settings.json"))
        try settingsFile.save(settings)

        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        var state = PersistedState()
        state.record(events)
        try store.save(state)

        let model = AppModel(store: store, settings: SettingsModel(
            file: settingsFile, displayPath: "~/.config/pullse/settings.json"
        ))
        model.showAsPolled(openPRs: sampleOpenPRs(now: Date()), at: Date().addingTimeInterval(-20))
        let asset = { (id: Int, name: String) in
            ReleaseAsset(id: id, name: name, url: "https://api.github.com/assets/\(id)", size: 0)
        }
        if update, let version = SemanticVersion("1.4.0") {
            model.updater.showAvailable(
                AvailableUpdate(
                    version: version, archive: asset(1, "Pullse-1.4.0.zip"),
                    checksum: asset(2, "Pullse-1.4.0.zip.sha256"), notes: "", pageURL: ""
                ),
                runningVersion: "1.3.1", build: "57"
            )
        }
        return model
    }

    /// The sample user's open PRs: two with activity in `sampleEvents`, one without.
    static func sampleOpenPRs(now: Date) -> [OpenPullRequest] {
        func pr(_ repo: String, _ number: Int, _ title: String, daysAgo: Double,
                draft: Bool = false, ci: OpenPullRequest.CIState?,
                review: OpenPullRequest.ReviewState?) -> OpenPullRequest {
            OpenPullRequest(
                repo: repo, number: number, title: title,
                url: "https://github.com/\(repo)/pull/\(number)",
                createdAt: now.addingTimeInterval(-daysAgo * 86_400),
                isDraft: draft, ci: ci, review: review
            )
        }
        return [
            pr("acme/api", 412, "Add rate limiting to the public API", daysAgo: 3,
               ci: .failing, review: .changesRequested),
            pr("acme/web", 88, "Dark mode for the dashboard", daysAgo: 5,
               ci: .passing, review: .approved),
            pr("acme/cli", 57, "Add a --json flag to status", daysAgo: 0.1,
               draft: true, ci: .running, review: .required),
        ]
    }

    static func sampleEvents(now: Date) -> [PREvent] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let api = ("acme/api", 412, "Add rate limiting to the public API")
        let web = ("acme/web", 88, "Dark mode for the dashboard")
        let docs = ("acme/docs", 31, "Document the webhook retry policy")

        func event(
            _ id: String, _ kind: PREvent.Kind, _ pr: (String, Int, String), _ author: String?,
            _ headline: String, _ snippet: String, _ date: Date,
            negative: Bool = false, unread: Bool = true
        ) -> PREvent {
            let url = "https://github.com/\(pr.0)/pull/\(pr.1)"
            return PREvent(
                id: id, kind: kind, repo: pr.0, number: pr.1, prTitle: pr.2, prURL: url,
                author: author, headline: headline, snippet: snippet, url: url, date: date,
                isNegative: negative, isUnread: unread
            )
        }

        return [
            event("1", .review, api, "alice", "alice requested changes",
                  "The limiter should key on the API token, not the client IP — proxies will share one bucket.",
                  ago(2), negative: true),
            event("2", .comment, api, "bob", "bob commented",
                  "Can we make the burst size configurable per plan?", ago(9)),
            event("3", .ci, api, nil, "CI failed: lint, unit-tests +1",
                  "lint, unit-tests, integration", ago(14), negative: true),
            event("4", .review, web, "carol", "carol approved",
                  "Looks great in both themes. Ship it!", ago(48), unread: false),
            event("5", .mention, docs, "dave", "dave mentioned you",
                  "@janedoe does the retry schedule here match what the API actually does?",
                  ago(95), unread: false),
            event("6", .comment, web, "erin", "erin commented",
                  "Nit: the toggle label should say Appearance.", ago(180), unread: false),
        ]
    }
}

/// Borderless windows can't become key by default.
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
