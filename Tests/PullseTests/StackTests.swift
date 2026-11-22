import Foundation
import Testing
@testable import PullseCore

private func open(_ fields: [[String: Any]]) throws -> [OpenPullRequest] {
    Stacks.assign(try snapshot(mine: fields).myPullRequests.map(OpenPullRequest.init))
}

private func stacks(_ prs: [OpenPullRequest]) -> [String: StackPosition] {
    Dictionary(uniqueKeysWithValues: prs.compactMap { pr in pr.stack.map { (pr.prLabel, $0) } })
}

// MARK: - Finding stacks

@Test func aChainOfBranchesIsAStackNumberedFromTheBottom() throws {
    let prs = try open([
        pr(number: 3, base: "branch-2"),
        pr(number: 1, base: "main"),
        pr(number: 2, base: "branch-1"),
    ])
    let stack = stacks(prs)
    #expect(prs.map(\.number) == [3, 1, 2])  // the order given
    #expect(stack["api#1"]?.depth == 1)
    #expect(stack["api#2"]?.depth == 2)
    #expect(stack["api#3"]?.depth == 3)
    #expect(Set(stack.values.map(\.height)) == [3])
    #expect(Set(stack.values.map(\.bottom)) == ["https://github.com/acme/api/pull/1"])
    #expect(stack["api#1"]?.description == "Bottom of the stack · below api#2")
    #expect(stack["api#2"]?.description == "On top of api#1 · below api#3")
    #expect(stack["api#3"]?.description == "On top of api#2")
}

@Test func aPullRequestOnNoneOfMyBranchesIsNotInAStack() throws {
    let prs = try open([pr(number: 1), pr(number: 2, base: "someone-elses-branch")])
    #expect(prs.allSatisfy { $0.stack == nil })
}

@Test func branchesOnlyStackWithinOneRepository() throws {
    let prs = try open([
        pr(repo: "acme/api", number: 1, head: "feature"),
        pr(repo: "acme/web", number: 2, base: "feature"),
    ])
    #expect(prs.allSatisfy { $0.stack == nil })
}

@Test func aBranchInAForkSaysNothingAboutTheBaseRepository() throws {
    let prs = try open([
        pr(number: 1, head: "feature", fromFork: true),
        pr(number: 2, base: "feature"),
    ])
    #expect(prs.allSatisfy { $0.stack == nil })
}

@Test func twoPullRequestsOnTheSameOneShareADepth() throws {
    let stack = stacks(try open([
        pr(number: 1),
        pr(number: 3, base: "branch-1"),
        pr(number: 2, base: "branch-1"),
    ]))
    #expect(stack["api#2"]?.depth == 2)
    #expect(stack["api#3"]?.depth == 2)
    #expect(stack["api#3"]?.height == 2)
    #expect(stack["api#1"]?.above == ["api#2", "api#3"])
}

@Test func pullRequestsBasedOnEachOtherHaveNoBottomAndNoStack() throws {
    let prs = try open([
        pr(number: 1, base: "branch-2"),
        pr(number: 2, base: "branch-1"),
    ])
    #expect(prs.allSatisfy { $0.stack == nil })
}

@Test func mentionedPullRequestsDecodeWithoutTheBranchFields() throws {
    let fields = pr(author: actor("alice"))
        .filter { !["baseRefName", "headRefName", "isCrossRepository"].contains($0.key) }
    let mentioned = try #require(try snapshot(mentioned: [fields]).mentionedPullRequests.first)
    #expect(mentioned.baseRefName == nil)
    #expect(OpenPullRequest(mentioned).headRef == nil)
}

// MARK: - Listing them

@Test func aStacksQuietPullRequestsStayTogetherBottomFirst() throws {
    let day: TimeInterval = 86_400
    let prs = try open([
        pr(number: 1, createdAt: t0.addingTimeInterval(-9 * day)),
        pr(number: 2, createdAt: t0.addingTimeInterval(-1 * day), base: "branch-1"),
        pr(number: 3, createdAt: t0.addingTimeInterval(-8 * day), base: "branch-2"),
        pr(number: 7, createdAt: t0.addingTimeInterval(-3 * day)),
        pr(number: 8, createdAt: t0.addingTimeInterval(-0.5 * day)),
    ])
    let groups = ActivityGroups.build(history: [], open: prs)
    // The stack goes where its newest PR (#2) would: after #8, before #7.
    #expect(groups.map(\.label) == ["api#8", "api#1", "api#2", "api#3", "api#7"])
    #expect(groups.map(\.stackedWithPrevious) == [false, false, true, true, false])
    #expect(groups.map(\.stackedWithNext) == [false, true, true, false, false])
}

@Test func aStackWithActivityMovesUpTogether() throws {
    let prs = try open([
        pr(number: 1), pr(number: 2, base: "branch-1"), pr(number: 3, base: "branch-2"), pr(number: 9),
    ])
    func comment(_ id: String, on number: Int, at date: Date) -> PREvent {
        PREvent(
            id: id, kind: .comment, repo: "acme/api", number: number, prTitle: "A change",
            prURL: "https://github.com/acme/api/pull/\(number)", author: "alice",
            headline: "alice commented", snippet: "", url: "https://github.com/c/\(id)", date: date
        )
    }
    let mention = PREvent(
        id: "m", kind: .mention, repo: "acme/docs", number: 4, prTitle: "Docs",
        prURL: "https://github.com/acme/docs/pull/4", author: "bob",
        headline: "bob mentioned you", snippet: "", url: "https://github.com/c/m", date: now
    )
    // Newest first: the mention, then #3's comment, then #1's, then #9's.
    let history = [mention, comment("c", on: 3, at: t0), comment("a", on: 1, at: t0), comment("n", on: 9, at: t0)]
    let groups = ActivityGroups.build(history: history, open: prs)
    #expect(groups.map(\.label) == ["docs#4", "api#1", "api#2", "api#3", "api#9"])
    #expect(groups.map(\.events.count) == [1, 1, 0, 1, 1])
    #expect(groups.map(\.stackedWithPrevious) == [false, false, true, true, false])
    #expect(groups.map(\.stackedWithNext) == [false, true, true, false, false])
}
