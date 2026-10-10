import Foundation

enum Queries {
    private static let fragments = """
    fragment ActorFields on Actor { login __typename }
    fragment IssueCommentFields on IssueComment {
      id body url createdAt author { ...ActorFields }
    }
    fragment ReviewCommentFields on PullRequestReviewComment {
      id body url createdAt publishedAt author { ...ActorFields }
    }
    fragment ConversationFields on PullRequest {
      id number title url body createdAt
      author { ...ActorFields }
      repository { nameWithOwner }
      comments(last: 30) { nodes { ...IssueCommentFields } }
      reviews(last: 50) {
        nodes {
          id state body url submittedAt author { ...ActorFields }
          comments(first: 30) { nodes { ...ReviewCommentFields } }
        }
      }
    }
    """

    /// Open PRs I authored in the org, with their conversation, draft and review status,
    /// and the check rollup of the head commit, one page at a time. GitHub gives a query
    /// about 10 seconds and each PR costs about a quarter of one, so a page of 50 timed out
    /// (HTTP 504) for someone with 40 or more open PRs.
    static let myPullRequestsPageSize = 15

    /// Stop after this many, so someone with hundreds of open PRs doesn't make every poll
    /// a dozen requests.
    static let myPullRequestsLimit = 100

    static let myPullRequests = """
    query($q: String!, $after: String) {
      viewer { login }
      search(query: $q, type: ISSUE, first: \(myPullRequestsPageSize), after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            ...ConversationFields
            isDraft reviewDecision mergeable
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    state
                    contexts(first: 100) {
                      nodes {
                        __typename
                        ... on CheckRun { id name status conclusion completedAt detailsUrl }
                        ... on StatusContext { id context state targetUrl createdAt }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """ + fragments

    /// Recently updated PRs by other people that mention me somewhere.
    static let mentions = """
    query($q: String!) {
      search(query: $q, type: ISSUE, first: 30) {
        nodes { ... on PullRequest { ...ConversationFields } }
      }
    }
    """ + fragments

    static func myPullRequestsSearch(org: String) -> String {
        // A fixed order, so a PR doesn't move between pages from one request to the next.
        "is:pr is:open author:@me org:\(org) sort:created-desc"
    }

    static func mentionsSearch(org: String, since: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: since)
        return "is:pr mentions:@me -author:@me org:\(org) updated:>=\(stamp)"
    }
}
