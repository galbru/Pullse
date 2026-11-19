import Foundation

// Deploys that wait for someone's approval after a merge. GitHub Actions holds a job
// that targets an environment with required reviewers, and records a Deployment for the
// commit in the WAITING state until someone approves it. Pullse reads those records (and
// the environments' protection rules, to know which environments are gated), so it works
// whatever the workflow looks like, and does nothing in a repository without such an
// environment.

/// One of my merged pull requests, from `Queries.myMergedPullRequests`.
public struct MergedPullRequest: Decodable, Sendable {
    public struct CheckSuite: Decodable, Sendable {
        public struct App: Decodable, Sendable { public let slug: String? }
        public struct WorkflowRun: Decodable, Sendable { public let url: String? }
        /// QUEUED, IN_PROGRESS, COMPLETED, WAITING, REQUESTED or PENDING.
        public let status: String?
        public let app: App?
        public var workflowRun: WorkflowRun? = nil
    }

    public struct MergeCommit: Decodable, Sendable {
        public let oid: String
        public let committedDate: Date?
        public let checkSuites: Connection<CheckSuite>?
    }

    public let id: String
    public let number: Int
    public let title: String
    public let url: String
    public let mergedAt: Date?
    public let repository: Repository
    public let mergeCommit: MergeCommit?

    /// Whether every GitHub Actions run on the merge commit has finished; nil when there
    /// are none (yet). Only Actions runs count: an environment approval is an Actions
    /// feature, and other apps can leave a suite queued forever.
    public var workflowsFinished: Bool? {
        let suites = actionsSuites
        guard !suites.isEmpty else { return nil }
        return suites.allSatisfy { $0.status == "COMPLETED" }
    }

    /// The workflow run still going on the merge commit (the one heading for the
    /// environment), else any of its runs.
    public var runLink: String? {
        let suites = actionsSuites
        let running = suites.filter { $0.status != "COMPLETED" } + suites
        return running.lazy.compactMap { GitHubLink.safe($0.workflowRun?.url) }.first
    }

    private var actionsSuites: [CheckSuite] {
        mergeCommit?.checkSuites?.items.filter { $0.app?.slug == "github-actions" } ?? []
    }
}

/// A repository's environments and newest deployments, from `Queries.repositoryDeployments`.
public struct RepositoryDeployments: Decodable, Sendable {
    public struct Environment: Decodable, Sendable {
        public struct Rule: Decodable, Sendable { public let type: String }
        public let name: String
        public let protectionRules: Connection<Rule>?
    }

    public struct Deployment: Decodable, Sendable {
        public struct Status: Decodable, Sendable {
            public let state: String
            /// For a deployment made by Actions, the workflow run.
            public let logUrl: String?
        }
        public struct DeployedCommit: Decodable, Sendable { public let committedDate: Date? }

        public let environment: String?
        public let commitOid: String
        public let state: String?
        public let createdAt: Date
        public let latestStatus: Status?
        public let commit: DeployedCommit?

        var status: String { latestStatus?.state ?? state ?? "" }
        /// Shipped. INACTIVE is a success that a newer deployment has since replaced.
        var succeeded: Bool { ["SUCCESS", "ACTIVE", "INACTIVE"].contains(status) }
        /// Approved and on its way out.
        var approved: Bool { ["QUEUED", "IN_PROGRESS"].contains(status) }
        var waiting: Bool { status == "WAITING" }
        var link: String? { GitHubLink.safe(latestStatus?.logUrl) }
    }

    /// Nil when the token can't read them.
    public let environments: Connection<Environment>?
    public let deployments: Connection<Deployment>

    /// The environments a deploy has to be approved for: those with required reviewers,
    /// or the ones named in the settings for this repository.
    public func gatedEnvironments(override: [String]?) -> [String] {
        if let override { return override }
        return (environments?.items ?? [])
            .filter { $0.protectionRules?.items.contains { $0.type == "REQUIRED_REVIEWERS" } == true }
            .map(\.name)
    }
}

/// What one poll found about deploys: my recently merged pull requests, and the
/// deployments of every repository they (or the ones already tracked) are in, keyed by
/// `owner/name`. A repository missing from `repositories` couldn't be read this time.
public struct DeploySnapshot: Sendable {
    public var merged: [MergedPullRequest]
    public var repositories: [String: RepositoryDeployments]

    public init(merged: [MergedPullRequest], repositories: [String: RepositoryDeployments]) {
        self.merged = merged
        self.repositories = repositories
    }
}

/// A merged pull request of mine whose deploy to one gated environment Pullse follows,
/// until it's out and the user clears it.
public struct DeployWatch: Codable, Sendable, Hashable, Identifiable {
    public enum Phase: String, Codable, Sendable, Comparable {
        /// Merged; the workflow hasn't reached the environment yet.
        case pending
        /// The deployment waits for someone to approve it.
        case waiting
        /// Approved: going out or out, its own or as part of a later deploy.
        case approved

        /// Most in need of attention first: waiting, then pending, then approved.
        public static func < (a: Phase, b: Phase) -> Bool { a.rank < b.rank }
        private var rank: Int {
            switch self {
            case .waiting: 0
            case .pending: 1
            case .approved: 2
            }
        }
    }

    public let repo: String
    public let number: Int
    public let title: String
    public let prURL: String
    public let environment: String
    /// The merge commit, and when it was made: a later commit deployed to the same
    /// environment carries this one with it.
    public let commit: String
    public let commitDate: Date?
    public let mergedAt: Date
    public var phase: Phase
    /// When it entered `phase`.
    public var changedAt: Date
    /// Set when a later commit's deploy took this one out, as its short sha.
    public var coveredBy: String?
    /// Cleared from the menu once approved; kept a while so it isn't found again.
    public var isCleared = false
    /// The workflow run to open from the menu: the one heading for the environment while
    /// pending, the deployment's while waiting (where it's approved), and the one that took
    /// it out once approved.
    public var link: String?

    public init(
        repo: String, number: Int, title: String, prURL: String, environment: String,
        commit: String, commitDate: Date?, mergedAt: Date, phase: Phase, changedAt: Date,
        coveredBy: String? = nil, isCleared: Bool = false, link: String? = nil
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.prURL = prURL
        self.environment = environment
        self.commit = commit
        self.commitDate = commitDate
        self.mergedAt = mergedAt
        self.phase = phase
        self.changedAt = changedAt
        self.coveredBy = coveredBy
        self.isCleared = isCleared
        self.link = link
    }

    public var id: String { prURL + "\n" + environment }

    public var prLabel: String { PREvent.label(repo: repo, number: number) }

    /// "Waiting for approval to deploy to production"
    public var summary: String {
        switch phase {
        case .pending: "Deploying, not yet at \(environment)"
        case .waiting: "Waiting for approval to deploy to \(environment)"
        case .approved:
            coveredBy.map { "Deployed to \(environment) with the later commit \($0)" }
                ?? "Approved for \(environment)"
        }
    }
}

public enum DeployTracker {
    /// Merged pull requests older than this aren't picked up.
    public static let lookback: TimeInterval = 24 * 60 * 60
    /// A merge whose workflow never reaches the environment, but whose runs can't be read
    /// either, stops being followed after this long.
    static let pendingLimit: TimeInterval = 24 * 60 * 60
    /// With no Actions run on the merge commit after this long, none is coming.
    static let noRunsLimit: TimeInterval = 15 * 60
    /// GitHub gives up on an unapproved deployment after 30 days.
    static let waitingLimit: TimeInterval = 30 * 24 * 60 * 60
    /// How long a cleared deploy is remembered, so it isn't found again. Must exceed
    /// `lookback`.
    static let clearedRetention: TimeInterval = 2 * 24 * 60 * 60

    /// Moves every followed deploy on to what `snapshot` says, starts following new
    /// merges into a gated environment, and stops following ones that will never need
    /// approval. Pure: no I/O, no clock.
    ///
    /// Events mark a deploy starting to wait for approval and being approved. A merge
    /// found already waiting or approved notifies only when it happened since the last
    /// poll, so a first launch doesn't announce yesterday's deploys.
    public static func update(
        _ watches: [DeployWatch], snapshot: DeploySnapshot, org: String,
        settings: DetectorSettings, lastPoll: Date?, now: Date
    ) -> (watches: [DeployWatch], events: [PREvent]) {
        let cutoff = (lastPoll ?? now).addingTimeInterval(-EventDetector.slack)
        let merged = Dictionary(snapshot.merged.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [DeployWatch] = []
        var events: [PREvent] = []

        func event(_ watch: DeployWatch, link: String?) {
            guard lastPoll != nil, settings.deploys, watch.phase != .pending,
                  !settings.isMuted(nameWithOwner: watch.repo) else { return }
            events.append(PREvent(
                id: "deploy:\(watch.environment):\(watch.prURL):\(watch.phase.rawValue)", kind: .deploy,
                repo: watch.repo, number: watch.number, prTitle: watch.title, prURL: watch.prURL,
                author: nil, headline: headline(watch), snippet: snippet(watch),
                url: link ?? watch.prURL, date: now, isNegative: watch.phase == .waiting
            ))
        }

        for var watch in watches {
            if watch.isCleared {
                if watch.mergedAt >= now.addingTimeInterval(-clearedRetention) { result.append(watch) }
                continue
            }
            guard let repository = snapshot.repositories[watch.repo] else {
                result.append(watch)  // not read this time; try again next poll
                continue
            }
            guard repository.gatedEnvironments(override: settings.deployEnvironments(for: watch.repo))
                .contains(where: { same($0, watch.environment) }),
                let found = resolve(watch, in: repository, pr: merged[watch.prURL], now: now)
            else { continue }
            watch.link = found.link ?? watch.link
            if found.phase != watch.phase {
                watch.phase = found.phase
                watch.changedAt = now
                watch.coveredBy = found.coveredBy
                event(watch, link: found.link)
            }
            result.append(watch)
        }

        let followed = Set(result.map(\.id))
        for pr in snapshot.merged {
            guard let mergedAt = pr.mergedAt, mergedAt >= now.addingTimeInterval(-lookback),
                  let commit = pr.mergeCommit,
                  pr.repository.nameWithOwner.lowercased().hasPrefix(org.lowercased() + "/"),
                  let repository = snapshot.repositories[pr.repository.nameWithOwner]
            else { continue }
            let gated = repository.gatedEnvironments(
                override: settings.deployEnvironments(for: pr.repository.nameWithOwner)
            )
            for environment in gated {
                var watch = DeployWatch(
                    repo: pr.repository.nameWithOwner, number: pr.number, title: pr.title, prURL: pr.url,
                    environment: environment, commit: commit.oid, commitDate: commit.committedDate,
                    mergedAt: mergedAt, phase: .pending, changedAt: now
                )
                guard !followed.contains(watch.id),
                      let found = resolve(watch, in: repository, pr: pr, now: now)
                else { continue }
                let recent = mergedAt >= cutoff
                // Already out before Pullse looked: nothing to follow.
                if found.phase == .approved, !recent { continue }
                watch.phase = found.phase
                watch.coveredBy = found.coveredBy
                watch.link = found.link
                result.append(watch)
                if recent { event(watch, link: found.link) }
            }
        }
        return (result, events)
    }

    /// Where one deploy stands; nil when it will never need approval (its workflow ended
    /// without reaching the environment, or the deployment was rejected or failed).
    static func resolve(
        _ watch: DeployWatch, in repository: RepositoryDeployments, pr: MergedPullRequest?, now: Date
    ) -> (phase: DeployWatch.Phase, coveredBy: String?, link: String?)? {
        let deployments = repository.deployments.items.filter {
            $0.environment.map { same($0, watch.environment) } == true
        }
        let own = deployments.first { $0.commitOid == watch.commit }  // newest first
        if let own, own.succeeded || own.approved {
            return (.approved, nil, own.link)
        }
        // On a branch that only moves forward, a later commit contains this one.
        if let date = watch.commitDate,
           let later = deployments.first(where: {
               $0.succeeded && $0.commitOid != watch.commit && ($0.commit?.committedDate ?? .distantPast) >= date
           }) {
            return (.approved, String(later.commitOid.prefix(7)), later.link)
        }
        if let own {
            guard own.waiting, now.timeIntervalSince(watch.mergedAt) < waitingLimit else { return nil }
            return (.waiting, nil, own.link)
        }
        let age = now.timeIntervalSince(watch.mergedAt)
        switch pr?.workflowsFinished {
        case true?: return nil
        case nil where pr != nil && age > noRunsLimit: return nil
        default: return age > pendingLimit ? nil : (.pending, nil, pr?.runLink)
        }
    }

    /// Short enough for one line in the menu; `snippet` says the rest.
    private static func headline(_ watch: DeployWatch) -> String {
        switch watch.phase {
        case .pending: "Deploying"
        case .waiting: "Waiting for approval: \(watch.environment)"
        case .approved: watch.coveredBy == nil ? "Approved for \(watch.environment)" : "Deployed to \(watch.environment)"
        }
    }

    private static func snippet(_ watch: DeployWatch) -> String {
        switch watch.phase {
        case .pending: ""
        case .waiting: "Someone who can approve deploys to \(watch.environment) has to review it."
        case .approved:
            watch.coveredBy.map { "With the later commit \($0); its own deploy was never approved." }
                ?? "The deploy is going out."
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }
}
