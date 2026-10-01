import Foundation

/// One of my open pull requests as the menu lists it, with where it stands.
public struct OpenPullRequest: Sendable, Hashable {
    public enum CIState: Sendable, Hashable { case passing, failing, running }
    public enum ReviewState: Sendable, Hashable { case approved, changesRequested, required }

    public let repo: String
    public let number: Int
    public let title: String
    public let url: String
    public let createdAt: Date
    public let isDraft: Bool
    /// Nil when the head commit has no checks.
    public let ci: CIState?
    /// Nil when the repository requires no review.
    public let review: ReviewState?

    public init(
        repo: String, number: Int, title: String, url: String, createdAt: Date,
        isDraft: Bool = false, ci: CIState? = nil, review: ReviewState? = nil
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.isDraft = isDraft
        self.ci = ci
        self.review = review
    }

    public init(_ pr: PullRequest) {
        let rollup = pr.commits?.items.last?.commit.statusCheckRollup
        let ci: CIState? = switch rollup?.state {
        case "SUCCESS": .passing
        case "FAILURE", "ERROR": .failing
        case "PENDING", "EXPECTED": .running
        default: nil
        }
        let review: ReviewState? = switch pr.reviewDecision {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .required
        default: nil
        }
        self.init(
            repo: pr.repository.nameWithOwner, number: pr.number, title: pr.title, url: pr.url,
            createdAt: pr.createdAt, isDraft: pr.isDraft ?? false, ci: ci, review: review
        )
    }

    /// "api#1964", as on `PREvent`.
    public var prLabel: String { PREvent.label(repo: repo, number: number) }
}

/// The menu's list: events grouped by pull request, and optionally every open PR of mine
/// even when nothing has happened on it.
public enum ActivityGroups {
    public struct Group: Sendable, Identifiable {
        public let prURL: String
        public let label: String
        public let title: String
        /// Set when this is one of my open PRs and the menu shows them.
        public let open: OpenPullRequest?
        /// Newest first; empty for an open PR with no activity.
        public let events: [PREvent]

        public var id: String { prURL }

        /// What clicking the heading opens: the pull request, or for a group that isn't
        /// one (the test notification) its newest event's link.
        public var link: String? { GitHubLink.safe(prURL, fallback: events.first?.url) }
    }

    /// Groups with events come first, ordered by their newest event. With `open` given
    /// (nil when the setting is off), open PRs with no events follow, newest opened first.
    public static func build(history: [PREvent], open: [OpenPullRequest]?) -> [Group] {
        let openByURL = Dictionary((open ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var byPR: [String: [PREvent]] = [:]
        for event in history {  // already newest first
            if byPR[event.prURL] == nil { order.append(event.prURL) }
            byPR[event.prURL, default: []].append(event)
        }
        let active = order.map { url -> Group in
            let events = byPR[url]!
            let pr = openByURL[url]
            return Group(
                prURL: url, label: pr?.prLabel ?? events[0].prLabel,
                title: pr?.title ?? events[0].prTitle, open: pr, events: events
            )
        }
        let quiet = openByURL.values
            .filter { byPR[$0.url] == nil }
            .sorted { ($0.createdAt, $0.url) > ($1.createdAt, $1.url) }
            .map { Group(prURL: $0.url, label: $0.prLabel, title: $0.title, open: $0, events: []) }
        return active + quiet
    }

    /// The open PRs the menu lists: those outside muted repositories, in the order given.
    public static func visible(_ open: [OpenPullRequest], settings: DetectorSettings) -> [OpenPullRequest] {
        open.filter { !settings.isMuted(nameWithOwner: $0.repo) }
    }
}
