import Foundation
import Testing
@testable import PullseCore

private func openPR(_ fields: [String: Any]) throws -> OpenPullRequest {
    OpenPullRequest(try #require(try snapshot(mine: [fields]).myPullRequests.first))
}

private func event(_ id: String, repo: String = "acme/api", number: Int = 1, at date: Date) -> PREvent {
    PREvent(
        id: id, kind: .comment, repo: repo, number: number, prTitle: "A change",
        prURL: "https://github.com/\(repo)/pull/\(number)", author: "alice",
        headline: "alice commented", snippet: "", url: "https://github.com/c/\(id)", date: date
    )
}

// MARK: - OpenPullRequest

@Test(arguments: [
    ("SUCCESS", OpenPullRequest.CIState.passing),
    ("FAILURE", .failing), ("ERROR", .failing),
    ("PENDING", .running), ("EXPECTED", .running),
])
func rollupStateBecomesTheCIChip(state: String, expected: OpenPullRequest.CIState) throws {
    #expect(try openPR(pr(rollupState: state)).ci == expected)
}

/// GitHub's rollup still fails on a run that a newer run of the same job replaced (one
/// cancelled by the next push or title edit, or a failure fixed by a re-run).
@Test(arguments: ["CANCELLED", "FAILURE"])
func aReplacedRunDoesNotFailTheCIChip(old: String) throws {
    let checks = [
        checkRun("a", name: "verify-title / check", conclusion: old, workflow: "W1", run: 10),
        checkRun("b", name: "verify-title / check", conclusion: "SUCCESS", workflow: "W1", run: 12),
        checkRun("c", name: "test", conclusion: "SUCCESS", workflow: "W2", run: 11),
        checkRun("d", name: "preview", conclusion: "SKIPPED", workflow: "W3", run: 13),
    ]
    #expect(try openPR(pr(checks: checks, rollupState: "FAILURE")).ci == .passing)
}

@Test
func aReplacedRunWithTheNewOneStillGoingIsRunning() throws {
    let checks = [
        checkRun("a", name: "check", conclusion: "CANCELLED", workflow: "W1", run: 10),
        checkRun("b", name: "check", conclusion: nil, workflow: "W1", run: 12),
    ]
    #expect(try openPR(pr(checks: checks, rollupState: "FAILURE")).ci == .running)
}

@Test
func aFailureThatIsStillCurrentKeepsTheCIChipFailing() throws {
    let replaced = [
        checkRun("a", name: "check", conclusion: "CANCELLED", workflow: "W1", run: 10),
        checkRun("b", name: "check", conclusion: "SUCCESS", workflow: "W1", run: 12),
    ]
    // Another job failed.
    let otherJob = replaced + [checkRun("c", name: "test", conclusion: "FAILURE", workflow: "W1", run: 11)]
    #expect(try openPR(pr(checks: otherJob, rollupState: "FAILURE")).ci == .failing)
    // The newer run is the one that failed.
    let newerFailed = [
        checkRun("a", name: "check", conclusion: "SUCCESS", workflow: "W1", run: 10),
        checkRun("b", name: "check", conclusion: "FAILURE", workflow: "W1", run: 12),
    ]
    #expect(try openPR(pr(checks: newerFailed, rollupState: "FAILURE")).ci == .failing)
    // Same job name in two different workflows is two jobs.
    let twoWorkflows = [
        checkRun("a", name: "build", conclusion: "FAILURE", workflow: "W1", run: 10),
        checkRun("b", name: "build", conclusion: "SUCCESS", workflow: "W2", run: 12),
    ]
    #expect(try openPR(pr(checks: twoWorkflows, rollupState: "FAILURE")).ci == .failing)
    // A failing legacy status or non-Actions check can't be replaced.
    let noWorkflow = replaced + [checkRun("c", name: "external", conclusion: "FAILURE")]
    #expect(try openPR(pr(checks: noWorkflow, rollupState: "FAILURE")).ci == .failing)
}

@Test
func aFullPageOfChecksKeepsTheRollup() throws {
    let replaced = [
        checkRun("a", name: "check", conclusion: "CANCELLED", workflow: "W1", run: 10),
        checkRun("b", name: "check", conclusion: "SUCCESS", workflow: "W1", run: 12),
    ]
    let filler = (0..<98).map { checkRun("f\($0)", name: "job \($0)", conclusion: "SUCCESS") }
    #expect(try openPR(pr(checks: replaced + filler, rollupState: "FAILURE")).ci == .failing)
}

@Test(arguments: [
    ("APPROVED", OpenPullRequest.ReviewState.approved),
    ("CHANGES_REQUESTED", .changesRequested),
    ("REVIEW_REQUIRED", .required),
])
func reviewDecisionBecomesTheReviewChip(decision: String, expected: OpenPullRequest.ReviewState) throws {
    #expect(try openPR(pr(reviewDecision: decision)).review == expected)
}

@Test func openPullRequestWithoutChecksOrRequiredReviewHasNoChips() throws {
    let open = try openPR(pr(repo: "acme/web", number: 7, isDraft: true))
    #expect(open.ci == nil)
    #expect(open.review == nil)
    #expect(open.isDraft)
    #expect(open.prLabel == "web#7")
    #expect(open.url == "https://github.com/acme/web/pull/7")
}

@Test func aPullRequestInTheMergeQueueIsMarked() throws {
    #expect(try openPR(pr(inMergeQueue: true)).inMergeQueue)
    #expect(try !openPR(pr()).inMergeQueue)
    let fields = pr(author: actor("alice")).filter { $0.key != "isInMergeQueue" }
    let mentioned = try #require(try snapshot(mentioned: [fields]).mentionedPullRequests.first)
    #expect(mentioned.isInMergeQueue == nil)
    #expect(!OpenPullRequest(mentioned).inMergeQueue)
}

@Test func mentionedPullRequestsStillDecodeWithoutTheStatusFields() throws {
    let fields = pr(author: actor("alice")).filter { !["isDraft", "reviewDecision", "commits"].contains($0.key) }
    let mentioned = try #require(try snapshot(mentioned: [fields]).mentionedPullRequests.first)
    #expect(mentioned.isDraft == nil)
    #expect(mentioned.reviewDecision == nil)
}

// MARK: - ActivityGroups

@Test func withoutOpenPullRequestsTheGroupsAreTheEventsByPullRequest() {
    let history = [event("a", number: 1, at: now), event("b", number: 2, at: t0), event("c", number: 1, at: t0)]
    let groups = ActivityGroups.build(history: history, open: nil)
    #expect(groups.map(\.label) == ["api#1", "api#2"])
    #expect(groups[0].events.map(\.id) == ["a", "c"])
    #expect(groups.allSatisfy { $0.open == nil })
}

@Test func quietOpenPullRequestsFollowTheActiveOnesNewestOpenedFirst() throws {
    let older = try openPR(pr(number: 2, createdAt: t0.addingTimeInterval(-7 * 86_400)))
    let newer = try openPR(pr(number: 3, createdAt: t0.addingTimeInterval(-3600)))
    let active = try openPR(pr(number: 1, rollupState: "FAILURE"))
    let groups = ActivityGroups.build(history: [event("a", number: 1, at: now)], open: [older, active, newer])
    #expect(groups.map(\.label) == ["api#1", "api#3", "api#2"])
    #expect(groups[0].open?.ci == .failing)
    #expect(groups[0].events.count == 1)
    #expect(groups[1].events.isEmpty)
}

@Test func activityOnPullRequestsThatArentMineOrOpenHasNoStatus() throws {
    let mine = try openPR(pr(number: 1))
    let mention = event("m", repo: "acme/docs", number: 9, at: now)
    let groups = ActivityGroups.build(history: [mention, event("a", number: 1, at: t0)], open: [mine])
    #expect(groups.map(\.label) == ["docs#9", "api#1"])
    #expect(groups[0].open == nil)
    #expect(groups[1].open == mine)
}

@Test func anOpenPullRequestListedTwiceShowsOnce() throws {
    let open = try openPR(pr(number: 1))
    #expect(ActivityGroups.build(history: [], open: [open, open]).count == 1)
}

@Test func openPullRequestsAreShownByDefault() throws {
    #expect(PullseSettings().showOpenPullRequests)
    let decoded = try JSONDecoder().decode(PullseSettings.self, from: Data(#"{ "org": "acme" }"#.utf8))
    #expect(decoded.showOpenPullRequests)
    let off = try JSONDecoder().decode(PullseSettings.self, from: Data(#"{ "showOpenPullRequests": false }"#.utf8))
    #expect(!off.showOpenPullRequests)
}

@Test func openPullRequestsInMutedRepositoriesAreHidden() throws {
    var settings = DetectorSettings()
    settings.mutedRepos = DetectorSettings.parseRepoList("sandbox, acme/legacy")
    let open = try [
        openPR(pr(repo: "acme/api", number: 1)),
        openPR(pr(repo: "acme/Sandbox", number: 2)),
        openPR(pr(repo: "acme/legacy", number: 3)),
        openPR(pr(repo: "other/legacy", number: 4)),
    ]
    #expect(ActivityGroups.visible(open, settings: settings).map(\.prLabel) == ["api#1", "legacy#4"])
}

@Test func draftsAreHiddenOnlyWhenIgnored() throws {
    let open = try [openPR(pr(number: 1)), openPR(pr(number: 2, isDraft: true))]
    var settings = DetectorSettings()
    #expect(ActivityGroups.visible(open, settings: settings).map(\.prLabel) == ["api#1", "api#2"])
    settings.ignoreDrafts = true
    #expect(ActivityGroups.visible(open, settings: settings).map(\.prLabel) == ["api#1"])
}

@Test func aHeadingOpensItsPullRequestOrElseItsNewestEventsLink() throws {
    let open = try openPR(pr(number: 1))
    let groups = ActivityGroups.build(history: [], open: [open])
    #expect(groups[0].link == "https://github.com/acme/api/pull/1")

    let test = PREvent(
        id: "test", kind: .test, repo: "", number: 0, prTitle: "Test notification",
        prURL: "pullse:test", author: nil, headline: "Test", snippet: "",
        url: "https://github.com/acme/pullse", date: now
    )
    let testGroup = ActivityGroups.build(history: [test], open: nil)[0]
    #expect(testGroup.label == "Pullse")
    #expect(testGroup.link == "https://github.com/acme/pullse")
}

@Test func openPullRequestsOpenedAtTheSameTimeKeepAStableOrder() throws {
    let open = try (1...5).map { try openPR(pr(number: $0)) }
    let first = ActivityGroups.build(history: [], open: open).map(\.label)
    for _ in 0..<10 {
        #expect(ActivityGroups.build(history: [], open: open.shuffled()).map(\.label) == first)
    }
}
