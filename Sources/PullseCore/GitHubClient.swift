import Foundation

public enum GitHubError: LocalizedError, Sendable {
    case ghNotFound
    case notLoggedIn(String)
    case http(Int, String)
    case graphQL([String])
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "The GitHub CLI (gh) was not found. Install it with `brew install gh`."
        case .notLoggedIn(let detail):
            return "gh is not logged in — run `gh auth login`. (\(detail))"
        case .http(let status, let body):
            // GitHub's error pages are HTML, which tells the user nothing in the menu.
            let detail = body.contains("<") ? "" : ": \(body)"
            switch status {
            case 502, 503, 504:
                return "GitHub timed out or is unavailable (HTTP \(status)). Pullse tries again at the next check."
            default:
                return "GitHub returned HTTP \(status)\(detail)"
            }
        case .graphQL(let messages):
            return "GitHub GraphQL error: \(messages.joined(separator: "; "))"
        case .badResponse(let detail):
            return "Unexpected response from GitHub: \(detail)"
        }
    }
}

public struct Snapshot: Sendable {
    public let login: String
    public let myPullRequests: [PullRequest]
    public let mentionedPullRequests: [PullRequest]
}

/// Talks to the GitHub GraphQL API with the token of the local `gh` login, so the app
/// needs no credentials of its own.
public actor GitHubClient {
    private let session: URLSession
    private var token: String?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch everything one poll needs. `mentionsSince` nil skips the mentions query.
    public func snapshot(org: String, mentionsSince: Date?) async throws -> Snapshot {
        let search = Queries.myPullRequestsSearch(org: org)
        let mine = try await Self.myPullRequests(limit: Queries.myPullRequestsLimit) { after in
            var variables = ["q": search]
            variables["after"] = after
            let page: MyPullRequestsData = try await self.graphQL(Queries.myPullRequests, variables: variables)
            return page
        }
        var mentioned: [PullRequest] = []
        if let since = mentionsSince {
            let data: MentionsData = try await graphQL(
                Queries.mentions, variables: ["q": Queries.mentionsSearch(org: org, since: since)]
            )
            mentioned = data.search.pullRequests
        }
        return Snapshot(
            login: mine.login,
            myPullRequests: mine.pullRequests,
            mentionedPullRequests: mentioned
        )
    }

    /// Pages through `fetch` (given the cursor to start after, nil for the first page)
    /// until there are no more or `limit` is reached. A PR that moved to the next page
    /// between two requests is kept once.
    static func myPullRequests(
        limit: Int, fetch: @Sendable (String?) async throws -> MyPullRequestsData
    ) async throws -> (login: String, pullRequests: [PullRequest]) {
        var login = ""
        var pullRequests: [PullRequest] = []
        var ids: Set<String> = []
        var after: String?
        repeat {
            let page = try await fetch(after)
            login = page.viewer.login
            for pr in page.search.pullRequests where ids.insert(pr.id).inserted {
                pullRequests.append(pr)
            }
            guard let info = page.search.pageInfo, info.hasNextPage, let cursor = info.endCursor
            else { break }
            after = cursor
        } while pullRequests.count < limit
        return (login, Array(pullRequests.prefix(limit)))
    }

    /// Releases of `repository` ("owner/name"), newest first.
    public func releases(repository: String) async throws -> [Release] {
        guard UpdateChecker.isValidRepository(repository),
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")
        else { throw GitHubError.badResponse("invalid repository \(repository)") }
        let data = try await withTokenRetry { token in
            try await self.get(url, accept: "application/vnd.github+json", token: token)
        }
        do {
            return try JSONDecoder.githubREST.decode([Release].self, from: data)
        } catch {
            throw GitHubError.badResponse(String(describing: error))
        }
    }

    /// A release asset's bytes.
    public func download(_ asset: ReleaseAsset) async throws -> Data {
        guard let url = URL(string: asset.url), url.host == "api.github.com" else {
            throw GitHubError.badResponse("unexpected asset URL \(asset.url)")
        }
        return try await withTokenRetry { token in
            try await self.get(url, accept: "application/octet-stream", token: token)
        }
    }

    func graphQL<T: Decodable>(_ query: String, variables: [String: String]) async throws -> T {
        let data = try await withTokenRetry { token in
            try await self.send(query, variables: variables, token: token)
        }
        return try Self.decode(data)
    }

    private func withTokenRetry(_ body: @Sendable (String) async throws -> Data) async throws -> Data {
        do {
            return try await body(try currentToken())
        } catch GitHubError.http(401, _) {
            // The gh token was rotated or re-issued since we cached it.
            token = nil
            return try await body(try currentToken())
        }
    }

    /// A GET, and the only other kind of request besides GraphQL queries: Pullse never
    /// writes to GitHub.
    private func get(_ url: URL, accept: String, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Pullse", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request, delegate: StripAuthorizationOnRedirect())
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.badResponse("not an HTTP response")
        }
        guard http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(http.statusCode, String(text.prefix(300)))
        }
        return data
    }

    private func send(_ query: String, variables: [String: String], token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Pullse", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["query": query, "variables": variables]
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.badResponse("not an HTTP response")
        }
        guard http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(http.statusCode, String(text.prefix(300)))
        }
        return data
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let envelope: GraphQLEnvelope<T>
        do {
            envelope = try JSONDecoder.github.decode(GraphQLEnvelope<T>.self, from: data)
        } catch {
            throw GitHubError.badResponse(String(describing: error))
        }
        // GraphQL can return partial data alongside errors (e.g. one inaccessible repo);
        // prefer the data when there is any.
        if let data = envelope.data {
            return data
        }
        throw GitHubError.graphQL(envelope.errors?.map(\.message) ?? ["no data"])
    }

    private func currentToken() throws -> String {
        if let token {
            return token
        }
        let fresh = try Self.tokenFromGh()
        token = fresh
        return fresh
    }

    /// `gh auth token`. GUI apps don't inherit the shell's PATH, so look in the usual
    /// Homebrew locations before falling back to PATH.
    static func tokenFromGh() throws -> String {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map { "\($0)/gh" }
        guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw GitHubError.ghNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "token", "--hostname", "github.com"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()

        let token = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !token.isEmpty else {
            let detail = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GitHubError.notLoggedIn(detail)
        }
        return token
    }
}

/// Asset downloads redirect from api.github.com to a pre-signed storage URL. The token
/// must not follow it there: it would leak to another host, and the storage service
/// rejects requests that carry a second form of authorization.
final class StripAuthorizationOnRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        var request = request
        if request.url?.host != task.originalRequest?.url?.host {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

struct GraphQLEnvelope<T: Decodable>: Decodable {
    struct Message: Decodable { let message: String }
    let data: T?
    let errors: [Message]?
}

extension JSONDecoder {
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
