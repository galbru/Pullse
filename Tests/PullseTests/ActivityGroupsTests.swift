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

@Test func openPullRequestsAreHiddenByDefault() throws {
    #expect(!PullseSettings().showOpenPullRequests)
    let decoded = try JSONDecoder().decode(PullseSettings.self, from: Data(#"{ "org": "acme" }"#.utf8))
    #expect(!decoded.showOpenPullRequests)
    let on = try JSONDecoder().decode(PullseSettings.self, from: Data(#"{ "showOpenPullRequests": true }"#.utf8))
    #expect(on.showOpenPullRequests)
}
