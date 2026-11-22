import Foundation
import Testing
@testable import PullseCore

// Builders for `DeployTracker`, decoded through the real models like the other fixtures.

private let api = "acme/api"

private func prURL(_ number: Int, repo: String = api) -> String {
    "https://github.com/\(repo)/pull/\(number)"
}

/// The merge commit of PR `number` is "c<number>", committed when it merged.
private func merged(
    _ number: Int, repo: String = api, at date: Date = t0, runs: [String]? = ["IN_PROGRESS"]
) -> [String: Any] {
    [
        "id": "PR_\(number)", "number": number, "title": "Change \(number)", "url": prURL(number, repo: repo),
        "mergedAt": stamp(date), "repository": ["nameWithOwner": repo],
        "mergeCommit": [
            "oid": "c\(number)", "committedDate": stamp(date),
            "checkSuites": ["nodes": (runs ?? []).enumerated().map { index, status in
                ["status": status, "app": ["slug": "github-actions"],
                 "workflowRun": ["url": "https://github.com/\(repo)/actions/runs/\(number)\(index)"]]
            }],
        ],
    ]
}

private func deployment(
    _ commit: String, _ status: String, environment: String = "production", committed: Date
) -> [String: Any] {
    [
        "environment": environment, "commitOid": commit, "state": status == "SUCCESS" ? "ACTIVE" : status,
        "createdAt": stamp(committed), "latestStatus": ["state": status, "logUrl": "https://github.com/\(api)/actions/runs/1/job/7"],
        "commit": ["committedDate": stamp(committed)],
    ]
}

private func repository(
    gated: [String] = ["production"], open: [String] = ["dev"], deployments: [[String: Any]] = []
) -> [String: Any] {
    let environments = gated.map { ["name": $0, "protectionRules": ["nodes": [["type": "REQUIRED_REVIEWERS"]]]] }
        + open.map { ["name": $0, "protectionRules": ["nodes": [["type": "BRANCH_POLICY"]]]] }
    return ["environments": ["nodes": environments], "deployments": ["nodes": deployments]]
}

private func deploySnapshot(
    merged: [[String: Any]], repositories: [String: [String: Any]] = [api: repository()]
) throws -> DeploySnapshot {
    let mergedJSON = try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["pullRequests": ["nodes": merged]]]])
    let page: MyMergedPullRequestsData = try GitHubClient.decode(mergedJSON)
    var decoded: [String: RepositoryDeployments] = [:]
    for (name, fields) in repositories {
        let json = try JSONSerialization.data(withJSONObject: ["data": ["repository": fields]])
        let data: RepositoryDeploymentsData = try GitHubClient.decode(json)
        decoded[name] = data.repository
    }
    return DeploySnapshot(merged: page.viewer.pullRequests.nodes.compactMap { $0 }, repositories: decoded)
}

private func track(
    _ snapshot: DeploySnapshot, settings: DetectorSettings = DetectorSettings(),
    lastPoll: Date? = lastPoll, at time: Date = now
) -> (watches: [DeployWatch], events: [PREvent]) {
    track([], snapshot, settings: settings, lastPoll: lastPoll, at: time)
}

private func track(
    _ watches: [DeployWatch], _ snapshot: DeploySnapshot, settings: DetectorSettings = DetectorSettings(),
    lastPoll: Date? = lastPoll, at time: Date = now
) -> (watches: [DeployWatch], events: [PREvent]) {
    DeployTracker.update(watches, snapshot: snapshot, org: "acme", settings: settings, lastPoll: lastPoll, now: time)
}

// MARK: - Following one deploy

@Test func aMergeIsFollowedFromPendingToWaitingToApproved() throws {
    let merge = merged(1, at: now)
    var (watches, events) = track(try deploySnapshot(merged: [merge]))
    #expect(watches.map(\.phase) == [.pending])
    #expect(watches.map(\.environment) == ["production"])
    #expect(events.isEmpty)

    let later = now.addingTimeInterval(300)
    (watches, events) = track(watches, try deploySnapshot(
        merged: [merge], repositories: [api: repository(deployments: [deployment("c1", "WAITING", committed: now)])]
    ), at: later)
    #expect(watches.map(\.phase) == [.waiting])
    #expect(events.map(\.headline) == ["Waiting for approval: production"])
    #expect(events.first?.isNegative == true)
    #expect(events.first?.kind == .deploy)
    #expect(events.first?.url == "https://github.com/\(api)/actions/runs/1")

    (watches, events) = track(watches, try deploySnapshot(
        merged: [merge], repositories: [api: repository(deployments: [deployment("c1", "IN_PROGRESS", committed: now)])]
    ), at: later.addingTimeInterval(60))
    #expect(watches.map(\.phase) == [.approved])
    #expect(watches.first?.coveredBy == nil)
    #expect(events.map(\.headline) == ["Approved for production"])
    #expect(events.first?.isNegative == false)
}

@Test func aLaterDeployCoversOneThatWasNeverApproved() throws {
    let deployments = [
        deployment("c2", "SUCCESS", committed: now.addingTimeInterval(60)),
        deployment("c1", "WAITING", committed: now),
    ]
    let (watches, events) = track(try deploySnapshot(
        merged: [merged(1, at: now), merged(2, at: now.addingTimeInterval(60))],
        repositories: [api: repository(deployments: deployments)]
    ), at: now.addingTimeInterval(120))
    let first = try #require(watches.first { $0.number == 1 })
    #expect(first.phase == .approved)
    #expect(first.coveredBy == "c2")
    #expect(first.summary == "Deployed to production with the later commit c2")
    #expect(events.first { $0.number == 1 }?.headline == "Deployed to production")
}

@Test func anOlderCommitDeployedLaterDoesNotCoverANewerOne() throws {
    // A re-run of an older commit's workflow, a rollback: c1 didn't go out with it.
    let deployments = [
        deployment("c0", "SUCCESS", committed: now.addingTimeInterval(-3600)),
        deployment("c1", "WAITING", committed: now),
    ]
    let (watches, _) = track(try deploySnapshot(
        merged: [merged(1, at: now)], repositories: [api: repository(deployments: deployments)]
    ))
    #expect(watches.map(\.phase) == [.waiting])
}

@Test func aDeployToAnotherEnvironmentDoesNotCount() throws {
    let deployments = [deployment("c1", "SUCCESS", environment: "dev", committed: now)]
    let (watches, _) = track(try deploySnapshot(
        merged: [merged(1, at: now)], repositories: [api: repository(deployments: deployments)]
    ))
    #expect(watches.map(\.phase) == [.pending])
}

// MARK: - What isn't followed

@Test func aRepositoryWithoutAGatedEnvironmentIsLeftAlone() throws {
    let (watches, events) = track(try deploySnapshot(
        merged: [merged(1, at: now)], repositories: [api: repository(gated: [])]
    ))
    #expect(watches.isEmpty)
    #expect(events.isEmpty)
}

@Test func aMergeWhoseWorkflowEndsWithoutReachingTheEnvironmentIsDropped() throws {
    // A change the workflow skips, like one to .github/ only.
    let (pending, _) = track(try deploySnapshot(merged: [merged(1, at: now)]))
    let (watches, events) = track(pending, try deploySnapshot(merged: [merged(1, at: now, runs: ["COMPLETED"])]))
    #expect(watches.isEmpty)
    #expect(events.isEmpty)
}

@Test func aMergeWithNoWorkflowRunIsDroppedAfterAWhile() throws {
    let merge = merged(1, at: now, runs: nil)
    #expect(track(try deploySnapshot(merged: [merge])).watches.map(\.phase) == [.pending])
    #expect(track(try deploySnapshot(merged: [merge]), at: now.addingTimeInterval(16 * 60)).watches.isEmpty)
}

@Test func aRejectedDeployIsDropped() throws {
    let (waiting, _) = track(try deploySnapshot(
        merged: [merged(1, at: now)], repositories: [api: repository(deployments: [deployment("c1", "WAITING", committed: now)])]
    ))
    let (watches, events) = track(waiting, try deploySnapshot(
        merged: [merged(1, at: now)], repositories: [api: repository(deployments: [deployment("c1", "FAILURE", committed: now)])]
    ))
    #expect(watches.isEmpty)
    #expect(events.isEmpty)
}

@Test func otherOrganizationsAndOldMergesAreIgnored() throws {
    let snapshot = try deploySnapshot(
        merged: [merged(1, repo: "other/api", at: now), merged(2, at: now.addingTimeInterval(-25 * 3600))],
        repositories: [api: repository(), "other/api": repository()]
    )
    #expect(track(snapshot).watches.isEmpty)
}

// MARK: - First look and notifications

@Test func theFirstPollFollowsWhatWaitsWithoutNotifying() throws {
    let deployments = [
        deployment("c2", "WAITING", committed: t0.addingTimeInterval(-600)),
        deployment("c1", "SUCCESS", committed: t0.addingTimeInterval(-3600)),
    ]
    let (watches, events) = track(try deploySnapshot(
        merged: [merged(1, at: t0.addingTimeInterval(-3600)), merged(2, at: t0.addingTimeInterval(-600))],
        repositories: [api: repository(deployments: deployments)]
    ), lastPoll: nil)
    // #1 was out before Pullse looked, so there's nothing to follow.
    #expect(watches.map(\.number) == [2])
    #expect(watches.map(\.phase) == [.waiting])
    #expect(events.isEmpty)
}

@Test func aMergeApprovedBetweenTwoPollsStillNotifies() throws {
    let (watches, events) = track(try deploySnapshot(
        merged: [merged(1, at: now)], repositories: [api: repository(deployments: [deployment("c1", "SUCCESS", committed: now)])]
    ))
    #expect(watches.map(\.phase) == [.approved])
    #expect(events.map(\.headline) == ["Approved for production"])
}

@Test func notificationsCanBeTurnedOffOrMuted() throws {
    let snapshot = try deploySnapshot(
        merged: [merged(1, at: now)], repositories: [api: repository(deployments: [deployment("c1", "WAITING", committed: now)])]
    )
    var off = DetectorSettings()
    off.deploys = false
    var muted = DetectorSettings()
    muted.mutedRepos = ["api"]
    for settings in [off, muted] {
        let (watches, events) = track(snapshot, settings: settings)
        #expect(watches.map(\.phase) == [.waiting])
        #expect(events.isEmpty)
    }
}

@Test func theSettingsCanNameTheEnvironments() throws {
    let deployments = [deployment("c1", "WAITING", environment: "dev", committed: now)]
    let snapshot = try deploySnapshot(merged: [merged(1, at: now)], repositories: [api: repository(deployments: deployments)])
    var named = DetectorSettings()
    named.deployEnvironments = ["api": ["dev"]]
    #expect(track(snapshot, settings: named).watches.map(\.environment) == ["dev"])
    #expect(track(snapshot, settings: named).watches.map(\.phase) == [.waiting])
    var none = DetectorSettings()
    none.deployEnvironments = ["acme/api": []]
    #expect(track(snapshot, settings: none).watches.isEmpty)
}

// MARK: - Keeping and clearing

@Test func aRepositoryThatCouldNotBeReadKeepsItsDeploys() throws {
    let (watches, _) = track(try deploySnapshot(merged: [merged(1, at: now)]))
    let (kept, events) = track(watches, try deploySnapshot(merged: [], repositories: [:]), at: now.addingTimeInterval(60))
    #expect(kept == watches)
    #expect(events.isEmpty)
}

@Test func aClearedDeployIsNotFoundAgainUntilItIsForgotten() throws {
    let snapshot = try deploySnapshot(
        merged: [merged(1, at: now)], repositories: [api: repository(deployments: [deployment("c1", "SUCCESS", committed: now)])]
    )
    var (watches, _) = track(snapshot)
    watches[0].isCleared = true
    let again = track(watches, snapshot, at: now.addingTimeInterval(60))
    #expect(again.watches.map(\.isCleared) == [true])
    #expect(again.events.isEmpty)
    #expect(track(watches, snapshot, at: now.addingTimeInterval(3 * 86_400)).watches.isEmpty)
}

@Test func aNewerDeployEventReplacesTheOlderOneInHistory() throws {
    let merge = merged(1, at: now)
    let (waiting, first) = track(try deploySnapshot(
        merged: [merge], repositories: [api: repository(deployments: [deployment("c1", "WAITING", committed: now)])]
    ))
    let (_, second) = track(waiting, try deploySnapshot(
        merged: [merge], repositories: [api: repository(deployments: [deployment("c1", "SUCCESS", committed: now)])]
    ), at: now.addingTimeInterval(60))
    var state = PersistedState()
    state.record(first)
    state.record(second)
    #expect(state.history.map(\.headline) == ["Approved for production"])
}

@Test func aStateFileFromBeforeDeploysStillLoads() throws {
    let json = Data(#"{"seen":{"seen":{}},"history":[]}"#.utf8)
    let state = try JSONDecoder.github.decode(PersistedState.self, from: json)
    #expect(state.deploys.isEmpty)
}

// MARK: - The menu

@Test func followedDeploysAreListedBetweenActivityAndQuietOpenPullRequests() throws {
    let (watches, _) = track(try deploySnapshot(merged: [merged(5, at: now), merged(6, at: now)], repositories: [
        api: repository(deployments: [deployment("c6", "WAITING", committed: now)]),
    ]))
    let comment = PREvent(
        id: "c", kind: .comment, repo: api, number: 1, prTitle: "Open", prURL: prURL(1), author: "alice",
        headline: "alice commented", snippet: "", url: prURL(1), date: now
    )
    let quiet = OpenPullRequest(repo: api, number: 2, title: "Quiet", url: prURL(2), createdAt: t0)
    let groups = ActivityGroups.build(history: [comment], open: [quiet], deploys: watches)
    // Both changed at the same time, so the higher URL first, like quiet open PRs.
    #expect(groups.map(\.label) == ["api#1", "api#6", "api#5", "api#2"])
    #expect(groups.map(\.deployPhase) == [nil, .waiting, .pending, nil])
    #expect(groups[1].title == "Change 6")
    // The heading opens the workflow run: the deployment's while waiting, where it's
    // approved, and the merge commit's while pending.
    #expect(groups[1].link == "https://github.com/\(api)/actions/runs/1")
    #expect(groups[2].link == "https://github.com/\(api)/actions/runs/50")
    #expect(groups[0].link == prURL(1))
}
