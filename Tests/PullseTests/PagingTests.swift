import Foundation
import Testing
@testable import PullseCore

// The open-PR query is paged because one request for 40 or more PRs ran past GitHub's
// time limit. These feed `GitHubClient.myPullRequests` canned pages instead of the network.

/// One page of the open-PR query as GitHub returns it: `numbers` are PR numbers in
/// acme/api, and `next` the cursor of the page after it, or nil for the last page.
private func page(_ numbers: [Int], next: String?) throws -> Data {
    let pageInfo: [String: Any] = ["hasNextPage": next != nil, "endCursor": next ?? NSNull()]
    return try JSONSerialization.data(withJSONObject: ["data": [
        "viewer": ["login": "me"],
        "search": ["pageInfo": pageInfo, "nodes": numbers.map { pr(number: $0) }],
    ]])
}

/// Pages keyed by the cursor that requests them ("" for the first).
private func fetchAll(_ pages: [String: Data], limit: Int = 100) async throws -> [Int] {
    try await GitHubClient.myPullRequests(limit: limit) { after in
        try GitHubClient.decode(try #require(pages[after ?? ""]))
    }.pullRequests.map(\.number)
}

@Suite struct MyPullRequestPagingTests {
    @Test func followsTheCursorToTheLastPage() async throws {
        let numbers = try await fetchAll([
            "": try page([1, 2], next: "a"),
            "a": try page([3, 4], next: "b"),
            "b": try page([5], next: nil),
        ])
        #expect(numbers == [1, 2, 3, 4, 5])
    }

    @Test func aPullRequestThatMovedToTheNextPageIsKeptOnce() async throws {
        let numbers = try await fetchAll([
            "": try page([1, 2], next: "a"),
            "a": try page([2, 3], next: nil),
        ])
        #expect(numbers == [1, 2, 3])
    }

    @Test func stopsAtTheLimit() async throws {
        let numbers = try await fetchAll([
            "": try page([1, 2], next: "a"),
            "a": try page([3, 4], next: "b"),
            // Never requested: the limit is reached first.
        ], limit: 3)
        #expect(numbers == [1, 2, 3])
    }

    @Test func aPageWithoutPageInfoIsTheLast() async throws {
        let json = try JSONSerialization.data(withJSONObject: ["data": [
            "viewer": ["login": "me"], "search": ["nodes": [pr(number: 7)]],
        ]])
        #expect(try await fetchAll(["": json]) == [7])
    }

    @Test func theQueryAsksForPagesSmallEnoughToFinishInTime() {
        #expect(Queries.myPullRequests.contains("first: \(Queries.myPullRequestsPageSize), after: $after"))
        #expect(Queries.myPullRequests.contains("pageInfo { hasNextPage endCursor }"))
        #expect(Queries.myPullRequestsPageSize <= 20)
    }
}

@Suite struct HTTPErrorTextTests {
    @Test func aTimeoutSaysSoWithoutGitHubsErrorPage() {
        let error = GitHubError.http(504, "<!DOCTYPE html>\n<!--\n\nHello future GitHubber!")
        #expect(error.errorDescription
            == "GitHub timed out or is unavailable (HTTP 504). Pullse tries again at the next check.")
    }

    @Test func anHTMLBodyIsLeftOut() {
        #expect(GitHubError.http(500, "<html><head>").errorDescription == "GitHub returned HTTP 500")
    }

    @Test func aPlainBodyIsKept() {
        #expect(GitHubError.http(403, #"{"message":"Resource not accessible"}"#).errorDescription
            == #"GitHub returned HTTP 403: {"message":"Resource not accessible"}"#)
    }
}
