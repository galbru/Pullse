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
    /// Waiting in the merge queue, to be merged once its turn comes and checks pass.
    public let inMergeQueue: Bool
    /// The branch it merges into, and its own branch. Nil when it comes from a fork,
    /// whose branch names say nothing about the base repository's.
    public let baseRef: String?
    public let headRef: String?
    /// Where it sits in a stack of my open PRs; nil when it isn't in one.
    /// `Stacks.assign` sets it.
    public internal(set) var stack: StackPosition?

    public init(
        repo: String, number: Int, title: String, url: String, createdAt: Date,
        isDraft: Bool = false, ci: CIState? = nil, review: ReviewState? = nil,
        baseRef: String? = nil, headRef: String? = nil, inMergeQueue: Bool = false
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.isDraft = isDraft
        self.ci = ci
        self.review = review
        self.baseRef = baseRef
        self.headRef = headRef
        self.inMergeQueue = inMergeQueue
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
        let fromFork = pr.isCrossRepository ?? false
        self.init(
            repo: pr.repository.nameWithOwner, number: pr.number, title: pr.title, url: pr.url,
            createdAt: pr.createdAt, isDraft: pr.isDraft ?? false, ci: ci, review: review,
            baseRef: fromFork ? nil : pr.baseRefName, headRef: fromFork ? nil : pr.headRefName,
            inMergeQueue: pr.isInMergeQueue ?? false
        )
    }

    /// "api#1964", as on `PREvent`.
    public var prLabel: String { PREvent.label(repo: repo, number: number) }
}

/// Where one PR sits in a stack: a chain of my open PRs in one repository, each based on
/// the branch of the one below it.
public struct StackPosition: Sendable, Hashable {
    /// The bottom PR's URL, the same for every PR in the stack.
    public let bottom: String
    /// 1 for the bottom PR, which merges into a branch that isn't one of my open PRs.
    public let depth: Int
    /// The longest chain in the stack. Several PRs can sit on the same one, so this can
    /// be less than the number of PRs in it.
    public let height: Int
    /// The PR it sits on, as "api#12"; nil at the bottom.
    public let below: String?
    /// The PRs sitting on it, as "api#14".
    public let above: [String]

    /// "On top of api#12 · below api#14".
    public var description: String {
        var parts: [String] = []
        if let below { parts.append("On top of \(below)") } else { parts.append("Bottom of the stack") }
        if !above.isEmpty { parts.append("below \(above.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}

/// Finds stacks among my open PRs from their branches alone, so it works whatever tool
/// made the stack (or none). When the bottom PR merges, GitHub moves the next one's
/// base to the default branch and the stack shrinks on the next poll by itself.
public enum Stacks {
    /// The PRs in the order given, each with its `stack` set (nil when it isn't in one).
    public static func assign(_ prs: [OpenPullRequest]) -> [OpenPullRequest] {
        // The PR whose head branch each (repo, branch) is. A branch can be the head of two
        // open PRs with different bases; the lowest number wins, so the result is stable.
        var byHead: [String: OpenPullRequest] = [:]
        for pr in prs.sorted(by: { ($0.repo, $0.number) < ($1.repo, $1.number) }) {
            guard let head = pr.headRef else { continue }
            let key = branchKey(pr.repo, head)
            if byHead[key] == nil { byHead[key] = pr }
        }
        func parent(of pr: OpenPullRequest) -> OpenPullRequest? {
            guard let base = pr.baseRef, let parent = byHead[branchKey(pr.repo, base)],
                  parent.url != pr.url else { return nil }
            return parent
        }

        // Each PR's chain down to the bottom, itself first. Nil for a cycle of PRs based
        // on each other, which has no bottom.
        func chain(from pr: OpenPullRequest) -> [OpenPullRequest]? {
            var chain = [pr]
            var seen: Set<String> = [pr.url]
            while let next = parent(of: chain[chain.count - 1]) {
                guard seen.insert(next.url).inserted else { return nil }
                chain.append(next)
            }
            return chain
        }
        let chains = Dictionary(uniqueKeysWithValues: prs.map { ($0.url, chain(from: $0)) })

        var members: [String: Int] = [:]
        var height: [String: Int] = [:]
        var above: [String: [OpenPullRequest]] = [:]
        for pr in prs {
            guard let chain = chains[pr.url] ?? nil, let bottom = chain.last else { continue }
            members[bottom.url, default: 0] += 1
            height[bottom.url] = max(height[bottom.url] ?? 0, chain.count)
            if chain.count > 1 { above[chain[1].url, default: []].append(pr) }
        }

        return prs.map { pr in
            var pr = pr
            guard let chain = chains[pr.url] ?? nil, let bottom = chain.last,
                  members[bottom.url, default: 0] > 1 else { return pr }
            pr.stack = StackPosition(
                bottom: bottom.url, depth: chain.count, height: height[bottom.url] ?? chain.count,
                below: chain.count > 1 ? chain[1].prLabel : nil,
                above: (above[pr.url] ?? []).sorted { $0.number < $1.number }.map(\.prLabel)
            )
            return pr
        }
    }

    private static func branchKey(_ repo: String, _ branch: String) -> String {
        repo.lowercased() + "\n" + branch
    }
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
        /// Set when the group just before or after it is in the same stack, so the menu
        /// joins them with a line.
        public var stackedWithPrevious = false
        public var stackedWithNext = false

        public var id: String { prURL }

        /// What clicking the heading opens: the pull request, or for a group that isn't
        /// one (the test notification) its newest event's link.
        public var link: String? { GitHubLink.safe(prURL, fallback: events.first?.url) }
    }

    /// Groups with events come first, ordered by their newest event. With `open` given
    /// (nil when the setting is off), open PRs with no events follow, newest opened first.
    /// The PRs of one stack stay together, bottom first: where its newest event puts it
    /// when any of them has one, else where its newest opened PR would be.
    public static func build(history: [PREvent], open: [OpenPullRequest]?) -> [Group] {
        let openByURL = Dictionary((open ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var byPR: [String: [PREvent]] = [:]
        for event in history {  // already newest first
            if byPR[event.prURL] == nil { order.append(event.prURL) }
            byPR[event.prURL, default: []].append(event)
        }
        // Every PR to list, by the stack it's in; a PR outside any stack is a stack of its
        // own here, keyed by its URL.
        var stackOf: [String: String] = [:]
        var members: [String: [String]] = [:]
        for url in order + openByURL.keys.sorted() where stackOf[url] == nil {
            let key = openByURL[url]?.stack?.bottom ?? url
            stackOf[url] = key
            members[key, default: []].append(url)
        }
        // Stacks with activity, in the order of their newest event.
        var stackOrder: [String] = []
        for url in order where !stackOrder.contains(stackOf[url]!) { stackOrder.append(stackOf[url]!) }
        let quiet = members.keys.filter { !stackOrder.contains($0) }
            .map { members[$0]!.compactMap { openByURL[$0] } }
            .sorted { newest($0) > newest($1) }
            .compactMap { $0.first.map { stackOf[$0.url]! } }
        stackOrder += quiet

        var groups: [Group] = []
        for key in stackOrder {
            let urls = members[key]!.sorted { a, b in
                let (pa, pb) = (openByURL[a], openByURL[b])
                return (pa?.stack?.depth ?? 0, pa?.number ?? 0, a) < (pb?.stack?.depth ?? 0, pb?.number ?? 0, b)
            }
            for (index, url) in urls.enumerated() {
                let events = byPR[url] ?? []
                let pr = openByURL[url]
                var group = Group(
                    prURL: url, label: pr?.prLabel ?? events[0].prLabel,
                    title: pr?.title ?? events[0].prTitle, open: pr, events: events
                )
                group.stackedWithPrevious = index > 0
                group.stackedWithNext = index < urls.count - 1
                groups.append(group)
            }
        }
        return groups
    }

    /// When a stack's newest PR was opened, with its URL to keep the order stable.
    private static func newest(_ stack: [OpenPullRequest]) -> (Date, String) {
        stack.map { ($0.createdAt, $0.url) }.max { $0 < $1 } ?? (.distantPast, "")
    }

    /// The open PRs the menu lists: those outside muted repositories, and not drafts when
    /// drafts are ignored, in the order given.
    public static func visible(_ open: [OpenPullRequest], settings: DetectorSettings) -> [OpenPullRequest] {
        open.filter { !settings.isMuted(nameWithOwner: $0.repo) && !(settings.ignoreDrafts && $0.isDraft) }
    }
}
