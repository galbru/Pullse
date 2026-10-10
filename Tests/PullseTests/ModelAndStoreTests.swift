import Foundation
import Testing
@testable import PullseCore

// MARK: - Decoding

@Test func searchDropsNodesThatAreNotPullRequests() throws {
    let json = try JSONSerialization.data(withJSONObject: [
        "data": ["search": ["nodes": [[:], NSNull(), pr(number: 7)]]],
    ])
    let data: MentionsData = try GitHubClient.decode(json)
    #expect(data.search.pullRequests.map(\.number) == [7])
}

@Test func nullConnectionEntriesAreSkipped() throws {
    var node = pr(comments: [comment("c1")])
    node["comments"] = ["nodes": [NSNull(), comment("c1"), NSNull()]]
    let json = try JSONSerialization.data(withJSONObject: ["data": ["search": ["nodes": [node]]]])
    let data: MentionsData = try GitHubClient.decode(json)
    #expect(data.search.pullRequests[0].comments.items.map(\.id) == ["c1"])
}

@Test func partialDataWithErrorsIsStillUsed() throws {
    let json = try JSONSerialization.data(withJSONObject: [
        "data": ["viewer": ["login": "me"], "search": ["nodes": [pr()]]],
        "errors": [["message": "Resource not accessible by integration"]],
    ])
    let data: MyPullRequestsData = try GitHubClient.decode(json)
    #expect(data.viewer.login == "me")
    #expect(data.search.pullRequests.count == 1)
}

@Test func malformedResponseIsABadResponse() {
    #expect {
        let _: MentionsData = try GitHubClient.decode(Data("<html>502</html>".utf8))
    } throws: { error in
        guard case GitHubError.badResponse = error else { return false }
        return true
    }
}

@Test func pullRequestWithoutCommitsHasNoChecks() throws {
    var node = pr()
    node.removeValue(forKey: "commits")
    let json = try JSONSerialization.data(withJSONObject: ["data": ["search": ["nodes": [node]]]])
    let data: MentionsData = try GitHubClient.decode(json)
    #expect(data.search.pullRequests[0].checks.isEmpty)
}

@Test func missingRollupHasNoChecks() throws {
    var node = pr()
    node["commits"] = ["nodes": [["commit": ["statusCheckRollup": NSNull()]]]]
    let json = try JSONSerialization.data(withJSONObject: ["data": ["search": ["nodes": [node]]]])
    let data: MentionsData = try GitHubClient.decode(json)
    #expect(data.search.pullRequests[0].checks.isEmpty)
}

@Test func reviewCommentDateFallsBackToCreatedAt() throws {
    let node = pr(reviews: [review("r1", state: "COMMENTED", comments: [
        comment("draftless", at: now),
        comment("published", at: t0, publishedAt: now),
    ])])
    let json = try JSONSerialization.data(withJSONObject: ["data": ["search": ["nodes": [node]]]])
    let data: MentionsData = try GitHubClient.decode(json)
    let comments = data.search.pullRequests[0].reviewComments
    #expect(comments.map(\.date) == [now, now])
    #expect(comments[1].createdAt == t0)
}

// MARK: - Models

@Test func botDetection() {
    #expect(Actor(login: "github-actions", typename: "Bot").isBot)
    #expect(Actor(login: "renovate[bot]", typename: nil).isBot)
    #expect(!Actor(login: "robot-fan", typename: "User").isBot)
}

@Test func checkOutcomes() throws {
    func decode(_ json: [String: Any]) throws -> CheckContext {
        try JSONDecoder.github.decode(CheckContext.self, from: JSONSerialization.data(withJSONObject: json))
    }
    let running = try decode(["__typename": "CheckRun", "id": "1", "status": "IN_PROGRESS"])
    #expect(running.outcome == nil)
    let done = try decode(["__typename": "CheckRun", "id": "2", "status": "COMPLETED", "conclusion": "FAILURE"])
    #expect(done.outcome == "FAILURE")
    #expect(try decode(["__typename": "StatusContext", "id": "3", "state": "ERROR"]).outcome == "FAILURE")
    #expect(try decode(["__typename": "StatusContext", "id": "4", "state": "EXPECTED"]).outcome == nil)
    #expect(try decode(["__typename": "CheckRun", "id": "5"]).displayName == "check")
}

@Test func labels() {
    #expect(Repository(nameWithOwner: "acme/api").name == "api")
    let event = PREvent(
        id: "e", kind: .comment, repo: "acme/web-app", number: 42, prTitle: "",
        prURL: "", author: nil, headline: "", snippet: "", url: "", date: now
    )
    #expect(event.prLabel == "web-app#42")
    #expect(event.isUnread)
}

@Test func searchQueries() {
    #expect(Queries.myPullRequestsSearch(org: "acme") == "is:pr is:open author:@me org:acme sort:created-desc")
    let since = Date(timeIntervalSince1970: 1_790_000_000)
    #expect(Queries.mentionsSearch(org: "acme", since: since)
        == "is:pr mentions:@me -author:@me org:acme updated:>=2026-09-21T14:13:20Z")
}

@Test func moreCleaning() {
    #expect(TextCleaner.clean("  \n\t ") == "")
    #expect(TextCleaner.clean("<!--\nmulti\nline\n-->ok") == "ok")
    let exact = String(repeating: "a", count: 10)
    #expect(TextCleaner.clean(exact, limit: 10) == exact)
    #expect(TextCleaner.clean("a <img src=\"x.png\"\n alt=\"y\"> b") == "a b")
}

// MARK: - Persistence

private func temporaryStore() -> StateStore {
    StateStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("pullse-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("nested/state.json"))
}

@Test func stateRoundTrips() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent().deletingLastPathComponent()) }

    var state = PersistedState()
    state.seen = SeenState(lastPollAt: now, seen: ["c1": t0])
    state.record([PREvent(
        id: "c1", kind: .review, repo: "o/r", number: 1, prTitle: "t", prURL: "u",
        author: "bob", headline: "bob approved", snippet: "nice", url: "u", date: t0,
        isNegative: false, isUnread: false
    )])
    try store.save(state)  // also creates the missing directories

    let loaded = store.load()
    #expect(loaded.seen == state.seen)
    #expect(loaded.history == state.history)
    #expect(loaded.history.first?.isUnread == false)
}

@Test func missingOrCorruptStateStartsFresh() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent().deletingLastPathComponent()) }

    #expect(store.load().seen.lastPollAt == nil)

    try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: store.url)
    let loaded = store.load()
    #expect(loaded.seen.lastPollAt == nil)
    #expect(loaded.history.isEmpty)
}

@Test func recordKeepsReadStateOfKnownEvents() {
    var state = PersistedState()
    let event = PREvent(
        id: "a", kind: .comment, repo: "o/r", number: 1, prTitle: "t", prURL: "u",
        author: nil, headline: "h", snippet: "", url: "u", date: t0
    )
    state.record([event])
    state.history[0].isUnread = false
    state.record([event])  // the same event again must not come back as unread
    #expect(state.history.count == 1)
    #expect(state.history[0].isUnread == false)
}

@Test func everyQueryIsReadOnly() {
    // Pullse must never change anything on GitHub: no GraphQL mutations.
    for query in [Queries.myPullRequests, Queries.mentions] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.hasPrefix("query"))
        #expect(!query.contains("mutation"))
    }
}

@Test func testItemsAreLabelledAsPullse() throws {
    let event = PREvent(
        id: "test-1", kind: .test, repo: "Pullse", number: 0, prTitle: "Test notification",
        prURL: "pullse:test", author: nil, headline: "Test notification", snippet: "",
        url: "https://github.com/acme/pullse", date: now
    )
    #expect(event.prLabel == "Pullse")
    // Survives the state file like any other event.
    var state = PersistedState()
    state.record([event])
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
    #expect(decoded.history.first?.kind == .test)
}
