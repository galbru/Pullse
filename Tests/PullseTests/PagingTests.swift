import Foundation
import Testing
@testable import PullseCore

// My open PRs are listed by id across every org, then fetched in full a few at a time,
// because one request for 40 or more PRs ran past GitHub's time limit. These feed
// `GitHubClient.myPullRequests` canned pages instead of the network.

/// One page of the id listing: `prs` are (owner, PR number) pairs, and `next` the cursor
/// of the page after it, or nil for the last page.
private func idPage(_ prs: [(String, Int)], next: String?) throws -> MyOpenPullRequestIDsData {
    let pageInfo: [String: Any] = ["hasNextPage": next != nil, "endCursor": next ?? NSNull()]
    return try GitHubClient.decode(try JSONSerialization.data(withJSONObject: ["data": [
        "viewer": ["login": "me", "pullRequests": [
            "pageInfo": pageInfo,
            "nodes": prs.map { owner, number in
                ["id": "PR_\(owner)/api_\(number)", "repository": ["owner": ["login": owner]]]
            },
        ]],
    ]]))
}

/// Records what was asked for, so a test can check the requests as well as the result.
private actor Requests {
    var details: [[String]] = []
    func add(_ ids: [String]) { details.append(ids) }
}

/// Id pages keyed by the cursor that requests them ("" for the first). The details for
/// an id are the fixture PR of that number, and an id in `deleted` comes back null.
private func fetchAll(
    _ pages: [String: MyOpenPullRequestIDsData], org: String = "acme", limit: Int = 100,
    pageSize: Int = 15, deleted: Set<String> = [], requests: Requests = Requests()
) async throws -> [Int] {
    try await GitHubClient.myPullRequests(
        org: org, limit: limit, pageSize: pageSize,
        ids: { after in try #require(pages[after ?? ""]) },
        details: { ids in
            await requests.add(ids)
            let nodes: [Any] = ids.map { id in
                if deleted.contains(id) { return NSNull() }
                let number = Int(id.split(separator: "_").last!)!
                let owner = String(id.dropFirst(3).split(separator: "/").first!)
                return pr(repo: "\(owner)/api", number: number)
            }
            return try GitHubClient.decode(try JSONSerialization.data(withJSONObject: ["data": ["nodes": nodes]]))
        }
    ).pullRequests.map(\.number)
}

@Suite struct MyPullRequestPagingTests {
    @Test func followsTheCursorToTheLastPage() async throws {
        let numbers = try await fetchAll([
            "": try idPage([("acme", 1), ("acme", 2)], next: "a"),
            "a": try idPage([("acme", 3), ("acme", 4)], next: "b"),
            "b": try idPage([("acme", 5)], next: nil),
        ])
        #expect(numbers == [1, 2, 3, 4, 5])
    }

    @Test func onlyTheOrgsPullRequestsAreFetched() async throws {
        let requests = Requests()
        let numbers = try await fetchAll([
            "": try idPage([("acme", 1), ("other", 2), ("Acme", 3), ("janedoe", 4)], next: nil),
        ], requests: requests)
        #expect(numbers == [1, 3])
        #expect(await requests.details == [["PR_acme/api_1", "PR_Acme/api_3"]])
    }

    @Test func detailsAreFetchedAPageAtATimeInOrder() async throws {
        let requests = Requests()
        let numbers = try await fetchAll([
            "": try idPage((1...5).map { ("acme", $0) }, next: nil),
        ], pageSize: 2, requests: requests)
        #expect(numbers == [1, 2, 3, 4, 5])
        #expect(await requests.details.map(\.count) == [2, 2, 1])
    }

    @Test func aPullRequestListedOnTwoPagesIsKeptOnce() async throws {
        let numbers = try await fetchAll([
            "": try idPage([("acme", 1), ("acme", 2)], next: "a"),
            "a": try idPage([("acme", 2), ("acme", 3)], next: nil),
        ])
        #expect(numbers == [1, 2, 3])
    }

    @Test func stopsAtTheLimit() async throws {
        let numbers = try await fetchAll([
            "": try idPage([("acme", 1), ("acme", 2)], next: "a"),
            "a": try idPage([("acme", 3), ("acme", 4)], next: "b"),
            // Never requested: the limit is reached first.
        ], limit: 3)
        #expect(numbers == [1, 2, 3])
    }

    @Test func aPullRequestDeletedSinceItWasListedIsDropped() async throws {
        let numbers = try await fetchAll([
            "": try idPage([("acme", 1), ("acme", 2)], next: nil),
        ], deleted: ["PR_acme/api_1"])
        #expect(numbers == [2])
    }

    @Test func noOpenPullRequestsMeansNoDetailRequest() async throws {
        let requests = Requests()
        #expect(try await fetchAll(["": try idPage([("other", 1)], next: nil)], requests: requests).isEmpty)
        #expect(await requests.details.isEmpty)
    }

    @Test func theQueriesListByAccountAndFetchSmallPages() {
        #expect(!Queries.myOpenPullRequestIDs.contains("search"))
        #expect(Queries.myOpenPullRequestIDs.contains("pullRequests(states: OPEN"))
        #expect(Queries.myOpenPullRequestIDs.contains("pageInfo { hasNextPage endCursor }"))
        #expect(Queries.myPullRequests.contains("nodes(ids: $ids)"))
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
